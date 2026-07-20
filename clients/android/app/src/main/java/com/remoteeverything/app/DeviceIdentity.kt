package com.remoteeverything.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayInputStream
import java.net.Socket
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

class DeviceIdentity(private val context: Context) : SetupIdentityStore {
    private val wrapAlias = "remote_everything_credential_wrap"
    private val preferences = context.getSharedPreferences("remote_everything_identity", Context.MODE_PRIVATE)
    private val validInstallationId = Regex("^[a-f0-9]{64}$")

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun hardwareWrappingKey(): SecretKey {
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

    private fun wrappingKey(): SecretKey = hardwareWrappingKey()

    override fun credentialPassword(installationId: String): String {
        requireInstallationId(installationId)
        preferences.getString("pending_password_$installationId", null)?.let {
            return unseal(it).toString(Charsets.US_ASCII)
        }
        val password = Base64.encodeToString(
            ByteArray(24).also(SecureRandom()::nextBytes),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        preferences.commitChanges { putString("pending_password_$installationId", seal(password.toByteArray(Charsets.US_ASCII))) }
        return password
    }

    override fun stageCredential(installationId: String, encoded: String, password: String) {
        requireInstallationId(installationId)
        val bytes = Base64.decode(encoded, Base64.DEFAULT)
        val loaded = loadCredential(bytes, password)
        verifyCredential(loaded)
        preferences.commitChanges {
            putString("staged_pkcs12_$installationId", seal(bytes))
            putString("staged_credential_password_$installationId", seal(password.toByteArray(Charsets.US_ASCII)))
            remove("pending_password_$installationId")
        }
        requireNotNull(stagedCredential(installationId)) { "待激活设备身份保存失败" }
    }

    override fun promoteCredential(installationId: String) {
        requireInstallationId(installationId)
        val credential = requireNotNull(preferences.getString("staged_pkcs12_$installationId", null)) { "没有待激活设备身份" }
        val password = requireNotNull(preferences.getString("staged_credential_password_$installationId", null)) { "没有待激活设备密码" }
        preferences.commitChanges {
            putString("credential_pkcs12_$installationId", credential)
            putString("credential_password_$installationId", password)
            remove("staged_pkcs12_$installationId")
            remove("staged_credential_password_$installationId")
        }
        requireNotNull(credential(installationId)) { "设备身份保存失败" }
    }

    fun hasCredential(installationId: String): Boolean = runCatching { credential(installationId) != null }.getOrDefault(false)

    override fun hasStagedCredential(installationId: String): Boolean = runCatching { stagedCredential(installationId) != null }.getOrDefault(false)

    override fun discardStagedCredential(installationId: String) {
        requireInstallationId(installationId)
        preferences.commitChanges {
            remove("staged_pkcs12_$installationId")
            remove("staged_credential_password_$installationId")
            remove("pending_password_$installationId")
        }
    }

    fun removeCredential(installationId: String) {
        requireInstallationId(installationId)
        preferences.commitChanges {
            remove("credential_pkcs12_$installationId")
            remove("credential_password_$installationId")
            remove("staged_pkcs12_$installationId")
            remove("staged_credential_password_$installationId")
            remove("pending_password_$installationId")
        }
    }

    fun clientIdentity(installationId: String): ClientIdentity {
        val loaded = requireNotNull(credential(installationId)) { "设备尚未配对" }
        return ClientIdentity(loaded.privateKey, loaded.chain.clone())
    }

    override fun stagedClientIdentity(installationId: String): ClientIdentity {
        val loaded = requireNotNull(stagedCredential(installationId)) { "设备身份尚未进入激活阶段" }
        return ClientIdentity(loaded.privateKey, loaded.chain.clone())
    }

    private fun credential(installationId: String): Credential? {
        requireInstallationId(installationId)
        val encoded = preferences.getString("credential_pkcs12_$installationId", null) ?: return null
        val password = preferences.getString("credential_password_$installationId", null) ?: return null
        return loadCredential(unseal(encoded), unseal(password).toString(Charsets.US_ASCII))
    }

    private fun stagedCredential(installationId: String): Credential? {
        requireInstallationId(installationId)
        val encoded = preferences.getString("staged_pkcs12_$installationId", null) ?: return null
        val password = preferences.getString("staged_credential_password_$installationId", null) ?: return null
        return loadCredential(unseal(encoded), unseal(password).toString(Charsets.US_ASCII))
    }

    private fun requireInstallationId(value: String) {
        require(validInstallationId.matches(value)) { "安装实例标识无效" }
    }

    private fun loadCredential(bytes: ByteArray, password: String): Credential {
        val store = KeyStore.getInstance("PKCS12")
        store.load(ByteArrayInputStream(bytes), password.toCharArray())
        val alias = store.aliases().toList().firstOrNull(store::isKeyEntry) ?: error("设备身份中没有私钥")
        val privateKey = store.getKey(alias, password.toCharArray()) as? PrivateKey ?: error("设备身份私钥无效")
        val chain = store.getCertificateChain(alias)?.map { it as X509Certificate }?.toTypedArray() ?: emptyArray()
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

    private data class Credential(val privateKey: PrivateKey, val chain: Array<X509Certificate>)
}

class StaticIdentityKeyManager(
    private val privateKey: PrivateKey,
    private val chain: Array<X509Certificate>,
) : X509ExtendedKeyManager() {
    private val identityAlias = "remote-everything"

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
