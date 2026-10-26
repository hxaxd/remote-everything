package com.remoteeverything.app

import com.remoteeverything.core.api.*
import com.remoteeverything.core.identity.*
import com.remoteeverything.core.model.*
import com.remoteeverything.core.model.Identity as GatewayIdentity
import com.remoteeverything.core.pathselect.PathSelector
import com.remoteeverything.core.setup.SetupUri
import com.sun.net.httpserver.*
import kotlinx.coroutines.*
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.*
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.*
import org.junit.Test
import java.math.BigInteger
import java.net.InetSocketAddress
import java.nio.file.Files
import java.security.*
import java.security.cert.X509Certificate
import java.util.Date
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.*

// Exercises production networking and controllers against real TLS and delayed answers.
class ClientRegressionTest {
    private fun material(name: String): Pkcs12.Material {
        val key = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val n = X500Name("CN=$name")
        val b = JcaX509v3CertificateBuilder(n, BigInteger(120,SecureRandom()), Date(System.currentTimeMillis()-60000), Date(System.currentTimeMillis()+86400000), n,key.public)
        b.addExtension(Extension.subjectAlternativeName,false,GeneralNames(arrayOf(GeneralName(GeneralName.dNSName,"localhost"),GeneralName(GeneralName.iPAddress,"127.0.0.1"))))
        val cert=JcaX509CertificateConverter().getCertificate(b.build(JcaContentSignerBuilder("SHA256withECDSA").build(key.private)))
        return Pkcs12.Material(key.private,listOf(cert))
    }
    private fun serverContext(m: Pkcs12.Material): SSLContext {
        val store=KeyStore.getInstance("PKCS12").apply{load(null,null);setKeyEntry("test",m.privateKey,"test".toCharArray(),m.chain.toTypedArray())}
        val km=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply{init(store,"test".toCharArray())}
        val trust=object:X509TrustManager{
            override fun getAcceptedIssuers()=emptyArray<X509Certificate>()
            override fun checkClientTrusted(c:Array<X509Certificate>,a:String){}
            override fun checkServerTrusted(c:Array<X509Certificate>,a:String){}
        }
        return SSLContext.getInstance("TLS").apply{init(km.keyManagers,arrayOf(trust),SecureRandom())}
    }
    private fun https(context:SSLContext, requireClient: Boolean = true, action:(HttpsExchange)->Unit):HttpsServer {
        val s=HttpsServer.create(InetSocketAddress("127.0.0.1",0),0)
        s.httpsConfigurator=object:HttpsConfigurator(context){override fun configure(p:HttpsParameters){p.setSSLParameters(context.defaultSSLParameters.apply{if(requireClient) needClientAuth=true else wantClientAuth=true})}}
        s.createContext("/"){e->try{action(e as HttpsExchange)}finally{e.close()}}
        s.start();return s
    }
    @Test fun malformed202IsUnreadable()=runBlocking {
        val s=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        s.createContext("/"){e->val b="not JSON".toByteArray();e.sendResponseHeaders(202,b.size.toLong());e.responseBody.use{it.write(b)}};s.start()
        try{val c=GatewayClients.pairing("http://127.0.0.1:${s.address.port}",null)
            val error=runCatching{c.activate("a".repeat(64))}.exceptionOrNull()
            assertTrue(error is UnreadableAnswer)
        }finally{s.stop(0)}
    }
    @Test fun invalidUtf8InvitationIsRejected(){
        val raw="remote-everything://setup?node=${"a".repeat(64)}&node_name=%FF&origin=https%3A%2F%2Fexample.com&invitation=${"b".repeat(43)}"
        assertTrue(runCatching { SetupUri.parse(raw) }.isFailure)
    }
    @Test fun rememberedRouteUsesCurrentDeclaration(){
        val cache=PathSelector.Cache();val p=Path("https://192.168.1.1:1",reachable=true,isPrivate=true,link=LinkKind.LOCAL)
        val node=Node("a".repeat(64),"A",listOf(p))
        cache.resolve(node,"same-network")
        assertEquals(LinkKind.TUNNEL,cache.resolve(node.copy(paths=listOf(p.copy(link=LinkKind.TUNNEL))),"same-network")!!.link)
    }
    @Test fun lateRefreshCannotRepopulateCacheAfterForget()=runBlocking{
        val origin="https://gateway.example";val started=CompletableDeferred<Unit>();val answer=CompletableDeferred<NodesResponse>()
        val directory=Files.createTempDirectory("client-audit-forget-").toFile()
        val cache=com.remoteeverything.core.store.NodeCacheStore(java.io.File(directory,"nodes.json"))
        val client=object:ControllerClient(origin){override suspend fun nodes():NodesResponse{started.complete(Unit);return answer.await()}}
        val controller=NodesController({client},cache)
        try{
            val inFlight=async{controller.refresh(listOf(controllerIdentity(origin)),"network")}
            started.await();controller.drop(origin);answer.complete(controllerNodes("a".repeat(64)))
            assertEquals(0,inFlight.await().size);assertFalse(cache.load().containsKey(origin))
        }finally{java.io.File(directory,"nodes.json").delete();directory.delete()}
    }
    @Test fun fallbackCatalogSelectsTheAnsweringRoute()=runBlocking{
        val first="https://first.example";val second="https://second.example"
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
        val p1=Path(first,reachable=true,latencyMs=1,isPrivate=false);val p2=Path(second,reachable=true,latencyMs=2,isPrivate=false)
        val node=Node("a".repeat(64),"A",listOf(p1,p2))
        val nc=NodesController({id->object:ControllerClient(id.origin){override suspend fun catalog(nodeId:String):CatalogResponse{if(id.origin==first)throw NetworkError(Exception("down"));return controllerCatalog("fallback")}}})
        val c=CatalogController(scope,nc,{"network"},{listOf(controllerIdentity(first),controllerIdentity(second))},{node},{})
        try{assertTrue(c.fetchCatalog(node) is CatalogUiState.Ready);assertEquals(second,nc.choosePath(node,"network")!!.origin)}finally{scope.cancel()}
    }
    @Test fun renewedCredentialUsesFreshPooledCertificate()=runBlocking{
        val sm=material("server");val old=material("old-device");val fresh=material("new-device")
        val seen=AtomicReference<String>()
        val s=https(serverContext(sm)){e->seen.set(Pkcs12.fingerprint(e.sslSession.peerCertificates[0] as X509Certificate));val b="{\"ok\":true,\"nodes\":[]}".toByteArray();e.sendResponseHeaders(200,b.size.toLong());e.responseBody.write(b)}
        try{
            val origin="https://127.0.0.1:${s.address.port}";val pin=ServerPin(Pkcs12.fingerprint(sm.certificate),Digest.publicKeyPin(sm.certificate))
            var held=old
            val vault=object:IdentityVault{override fun load(origin:String)=held;override fun store(origin:String,material:Pkcs12.Material){};override fun delete(origin:String){}}
            val pool=GatewayClientPool();val identity=GatewayIdentity(origin,"test",Pkcs12.fingerprint(old.certificate),origin,pin,0)
            pool.deviceClient(identity,vault)!!.nodes();held=fresh
            pool.deviceClient(identity.copy(certFingerprint=Pkcs12.fingerprint(fresh.certificate)),vault)!!.nodes()
            assertEquals(Pkcs12.fingerprint(fresh.certificate),seen.get())
        }finally{s.stop(0)}
    }
    @Test fun redirectedDownloadDoesNotPresentGatewayCertificateOutsideItsNamespace() {
        val sm=material("server");val device=material("device");val context=serverContext(sm)
        val seen=AtomicReference<String>()
        val dest=https(context,false){e->seen.set(runCatching { Pkcs12.fingerprint(e.sslSession.peerCertificates[0] as X509Certificate) }.getOrNull());val b="file".toByteArray();e.sendResponseHeaders(200,b.size.toLong());e.responseBody.write(b)}
        val start=https(context){e->e.responseHeaders.add("Location","https://localhost:${dest.address.port}/file");e.sendResponseHeaders(302,-1)}
        try {
            val origin="https://127.0.0.1:${start.address.port}"
            val pin=ServerPin(Pkcs12.fingerprint(sm.certificate),Digest.publicKeyPin(sm.certificate))
            val gateway=GatewayClients.rawTransport(origin,device,pin)
            val plain=gatewayOkHttpClient("https://localhost:${dest.address.port}",null,pin,false,10)
            ScopedDownload(origin,{gateway},plain,{null},{_,_->}).execute("$origin/download","Test").use { assertEquals(200,it.code);assertEquals("file",it.body!!.string()) }
            assertNull(seen.get())
        } finally { start.stop(0);dest.stop(0) }
    }
}
