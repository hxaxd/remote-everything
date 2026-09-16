package com.remoteeverything.app

import org.json.JSONArray
import org.json.JSONObject

object ProfileCodec {
    private val fields = setOf("installation_id", "name", "mode", "origin", "fingerprint", "public_key_pin")

    fun encode(value: ConnectionConfig): JSONObject = JSONObject()
        .put("installation_id", value.installationId)
        .put("name", value.name)
        .put("mode", value.mode)
        .put("origin", value.gatewayOrigin)
        .put("fingerprint", value.gatewayFingerprint)
        .put("public_key_pin", value.gatewayPublicKeyPin)

    fun encodeAll(values: List<ConnectionConfig>): String = JSONArray().apply { values.forEach { put(encode(it)) } }.toString()

    fun decode(value: JSONObject): ConnectionConfig {
        val keys = value.keys().asSequence().toSet()
        require(keys == fields) { "连接配置字段无效" }
        return AppConfig.create(
            value.getString("installation_id"),
            value.getString("name"),
            value.getString("mode"),
            value.getString("origin"),
            value.getString("fingerprint"),
            value.getString("public_key_pin"),
        )
    }

    fun decodeAll(encoded: String): List<ConnectionConfig> {
        val array = JSONArray(encoded)
        return buildList {
            for (index in 0 until array.length()) add(decode(array.getJSONObject(index)))
        }
    }
}
