package com.remoteeverything.app

import com.remoteeverything.core.api.AppCode
import com.remoteeverything.core.api.AppDto
import com.remoteeverything.core.api.CatalogCode
import com.remoteeverything.core.api.CatalogResponse
import com.remoteeverything.core.api.ControlResponse
import com.remoteeverything.core.api.GatewayClient
import com.remoteeverything.core.api.NodeDto
import com.remoteeverything.core.api.NodesResponse
import com.remoteeverything.core.api.PairRequest
import com.remoteeverything.core.api.PairingResponse
import com.remoteeverything.core.model.Identity

internal open class ControllerClient(override val origin: String = "https://gateway.example") : GatewayClient {
    override suspend fun pair(request: PairRequest): PairingResponse = error("unused")
    override suspend fun activate(nodeId: String): CatalogResponse = error("unused")
    override suspend fun nodes(): NodesResponse = error("unused")
    override suspend fun catalog(nodeId: String): CatalogResponse = error("unused")
    override suspend fun status(nodeId: String, appId: String): ControlResponse = error("unused")
    override suspend fun start(nodeId: String, appId: String): ControlResponse = error("unused")
    override suspend fun stop(nodeId: String, appId: String): ControlResponse = error("unused")
    override suspend fun open(nodeId: String, appId: String): String = error("unused")
}

internal fun controllerIdentity(origin: String) = Identity(origin, "Phone", "f".repeat(64), origin, null, 0)

internal fun controllerNodes(id: String) = NodesResponse(true, listOf(NodeDto(id, id)))

internal fun controllerCatalog(name: String, code: AppCode = AppCode.READY) = CatalogResponse(
    true, true, CatalogCode.READY,
    listOf(AppDto("dsh", name, "", "", "", "", true,
        code == AppCode.READY || code == AppCode.STARTING,
        code == AppCode.READY || code == AppCode.STOPPING, code)),
)
