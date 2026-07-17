package com.agentremote.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayInputStream
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.X509Certificate
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager

class DeviceIdentity(private val context: Context) {
    private val proofAlias = "agent_remote_device_key_v1"
    private val wrapAlias = "agent_remote_credential_wrap_v1"
    private val preferences = context.getSharedPreferences("agent_remote_identity", Context.MODE_PRIVATE)

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun ensureKey(): java.security.PublicKey {
        val store = keyStore()
        store.getCertificate(proofAlias)?.publicKey?.let { return it }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        generator.initialize(
            KeyGenParameterSpec.Builder(
                proofAlias,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
            )
                .setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKeyPair().public
    }

    fun publicKeyPem(): String {
        val body = Base64.encodeToString(ensureKey().encoded, Base64.NO_WRAP).chunked(64).joinToString("\n")
        return "-----BEGIN PUBLIC KEY-----\n$body\n-----END PUBLIC KEY-----\n"
    }

    fun createProof(deviceName: String): Proof {
        ensureKey()
        val nonce = ByteArray(32).also(SecureRandom()::nextBytes)
        val message = "KIMI-REMOTE-ENROLL-V1\u0000$deviceName\u0000".toByteArray(Charsets.UTF_8) + nonce
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(proofPrivateKey())
        signer.update(message)
        return Proof(
            nonce = Base64.encodeToString(nonce, Base64.NO_WRAP),
            signature = Base64.encodeToString(signer.sign(), Base64.NO_WRAP),
        )
    }

    fun credentialPassword(): String {
        preferences.getString("pending_credential_password", null)?.let {
            return unseal(it).toString(Charsets.US_ASCII)
        }
        val password = Base64.encodeToString(
            ByteArray(24).also(SecureRandom()::nextBytes),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        check(preferences.edit().putString("pending_credential_password", seal(password.toByteArray(Charsets.US_ASCII))).commit())
        return password
    }

    fun installCredential(encoded: String, password: String) {
        val bytes = Base64.decode(encoded, Base64.DEFAULT)
        val loaded = loadCredential(bytes, password)
        verifyCredential(loaded)
        check(
            preferences.edit()
                .putString("credential_pkcs12", seal(bytes))
                .putString("credential_password", seal(password.toByteArray(Charsets.US_ASCII)))
                .remove("pending_credential_password")
                .commit(),
        )
        requireNotNull(credential()) { "设备身份保存失败" }
    }

    fun isApproved(): Boolean = runCatching { credential() != null }.getOrDefault(false)

    fun privateKey(): PrivateKey = requireNotNull(credential()) { "设备尚未批准" }.privateKey

    fun certificate(): X509Certificate? = credential()?.chain?.firstOrNull()

    fun certificateChain(): Array<X509Certificate> = credential()?.chain?.clone() ?: emptyArray()

    fun keyManager(): X509ExtendedKeyManager {
        val loaded = requireNotNull(credential()) { "设备尚未批准" }
        return StaticIdentityKeyManager(loaded.privateKey, loaded.chain)
    }

    private fun proofPrivateKey(): PrivateKey = keyStore().getKey(proofAlias, null) as PrivateKey

    private fun credential(): Credential? {
        val encoded = preferences.getString("credential_pkcs12", null) ?: return null
        val password = preferences.getString("credential_password", null) ?: return null
        return loadCredential(unseal(encoded), unseal(password).toString(Charsets.US_ASCII))
    }

    private fun loadCredential(bytes: ByteArray, password: String): Credential {
        val store = KeyStore.getInstance("PKCS12")
        store.load(ByteArrayInputStream(bytes), password.toCharArray())
        val alias = store.aliases().toList().firstOrNull(store::isKeyEntry) ?: error("设备身份中没有私钥")
        val privateKey = store.getKey(alias, password.toCharArray()) as? PrivateKey ?: error("设备身份私钥无效")
        val chain: Array<X509Certificate> =
            store.getCertificateChain(alias)?.map { it as X509Certificate }?.toTypedArray() ?: emptyArray()
        require(chain.isNotEmpty()) { "设备身份中没有证书" }
        return Credential(privateKey, chain)
    }

    private fun verifyCredential(credential: Credential) {
        val algorithm = when (credential.privateKey.algorithm.uppercase()) {
            "EC" -> "SHA256withECDSA"
            "RSA" -> "SHA256withRSA"
            else -> error("设备身份使用了不支持的密钥")
        }
        val challenge = ByteArray(32).also(SecureRandom()::nextBytes)
        val signer = Signature.getInstance(algorithm).apply {
            initSign(credential.privateKey)
            update(challenge)
        }
        val verifier = Signature.getInstance(algorithm).apply {
            initVerify(credential.chain.first().publicKey)
            update(challenge)
        }
        require(verifier.verify(signer.sign())) { "设备证书与私钥不匹配" }
    }

    private fun wrappingKey(): SecretKey {
        (keyStore().getKey(wrapAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                wrapAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun seal(value: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val packed = cipher.iv + cipher.doFinal(value)
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    private fun unseal(value: String): ByteArray {
        val packed = Base64.decode(value, Base64.DEFAULT)
        require(packed.size > 28) { "加密的设备身份无效" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, packed.copyOfRange(0, 12)))
        return cipher.doFinal(packed.copyOfRange(12, packed.size))
    }

    data class Proof(val nonce: String, val signature: String)
    private data class Credential(val privateKey: PrivateKey, val chain: Array<X509Certificate>)
}

class StaticIdentityKeyManager(
    private val privateKey: PrivateKey,
    private val chain: Array<X509Certificate>,
) : X509ExtendedKeyManager() {
    private val identityAlias = "agent-remote"

    private fun supports(keyType: String?): Boolean {
        if (keyType == null) return true
        val requested = keyType.uppercase()
        return when (privateKey.algorithm.uppercase()) {
            "EC" -> requested == "EC" || requested.startsWith("EC_")
            else -> requested == privateKey.algorithm.uppercase()
        }
    }

    private fun choose(keyTypes: Array<out String>?): String? =
        if (keyTypes.isNullOrEmpty() || keyTypes.any(::supports)) identityAlias else null

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
        if (supports(keyType)) arrayOf(identityAlias) else null
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? = choose(keyType)
    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
    override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == identityAlias) chain.clone() else null
    override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == identityAlias) privateKey else null
    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?): String? = choose(keyType)
    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String? = null
}
