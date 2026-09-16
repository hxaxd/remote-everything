// genbundle 为节点 e2e harness 生成一份固定身份与控制令牌的节点 bootstrap
// bundle。真实部署的 bundle 由网关侧生成，这个工具只服务测试。
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
)

func main() {
	gatewayRoot := flag.String("gateway", "", "gateway material directory (absolute)")
	bootstrap := flag.String("bootstrap", "", "node bootstrap output directory (absolute)")
	installationID := flag.String("installation-id", "", "64-hex installation id")
	controlToken := flag.String("control-token", "", "64-hex control token")
	flag.Parse()
	if flag.NFlag() != 4 || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: genbundle -gateway DIR -bootstrap DIR -installation-id HEX64 -control-token HEX64")
		os.Exit(64)
	}
	material, err := deploymentbootstrap.EnsureGatewayMaterial(*gatewayRoot, *installationID, *controlToken)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := deploymentbootstrap.WriteNodeBundle(*bootstrap, material); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
