package com.remoteeverything.app.web

import android.webkit.ClientCertRequest
import com.remoteeverything.core.identity.Pkcs12

/**
 * Answers client certificate challenges using credentials stored in the vault.
 */
class WebClientCertHandler(
    private val materialProvider: () -> Pkcs12.Material?,
    private val isAllowedHost: (String) -> Boolean,
) {
    fun handle(request: ClientCertRequest) {
        val material = materialProvider() ?: return
        val host = request.host.orEmpty()
        if (!isAllowedHost(host)) {
            request.cancel()
            return
        }
        request.proceed(material.privateKey, material.chain.toTypedArray())
    }
}
