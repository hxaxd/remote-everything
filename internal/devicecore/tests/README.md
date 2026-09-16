# 设备信任的部署验收脚本

`pairing_pkcs12.py` 不是单测，而是对着**已部署的真实网关**跑一遍配对：它用 openssl 取出
PKCS#12 里的客户端证书、核对指纹、再用该证书发起一次 mTLS 请求。由 CI 做语法检查，实际执行
需要部署环境（`PUBLIC_ORIGIN`、`SERVER_STATE_ROOT`、`GATEWAY_BIN`）。

配对与设备记录属于 `internal/devicecore`，所以脚本随它一起放，而不是挂在某一个入口下面。
