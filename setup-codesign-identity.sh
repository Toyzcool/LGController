#!/bin/zsh
# 一次性：在登录钥匙串创建一个自签名代码签名证书「LGController Self-Signed」。
#
# 为什么要它：ad-hoc 签名（codesign -s -）每次重建的 cdhash 都变，macOS 的辅助功能（TCC）
# 授权是绑签名的，于是每次重建都要重新授权。用一个固定的自签名证书后，签名的「设计器名」
# 稳定不变，重建后授权依旧有效，无需再次到系统设置里勾选。
#
# 运行一次即可。之后 ./build.sh 会自动检测并使用该证书。
set -e

NAME="LGController Self-Signed"

# 注意：用 find-identity -p codesigning（不加 -v）——自签名证书未被信任，-v 会把它过滤掉，
# 但 codesign 仍能按名字正常使用它签名，且设计器名基于证书哈希、跨重建稳定。
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✅ 证书「$NAME」已存在，无需重复创建。直接运行 ./build.sh 即可。"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ 生成自签名证书（codeSigning）"
cat > "$TMP/cert.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = LGController Self-Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null

LOGIN_KC="$(security default-keychain -d user | tr -d ' "')"
echo "▸ 导入登录钥匙串: $LOGIN_KC"

import_ok=false

# 方式 A（首选）：证书与私钥分开导入 PEM——不受 openssl 版本影响。
# -A：允许所有程序使用私钥（本地开发用，免除 codesign 弹框）
if security import "$TMP/cert.pem" -k "$LOGIN_KC" -A -T /usr/bin/codesign 2>/dev/null \
   && security import "$TMP/key.pem" -k "$LOGIN_KC" -A -T /usr/bin/codesign 2>/dev/null; then
  import_ok=true
fi

# 方式 B（兜底）：PKCS12 + -legacy（解决 OpenSSL 3.x MAC 与 macOS 不兼容）
if [ "$import_ok" = false ]; then
  echo "  PEM 分开导入未成功，改用 PKCS12(-legacy) …"
  LEGACY=""
  openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY="-legacy"
  openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:lgcontroller -name "$NAME" 2>/dev/null
  security import "$TMP/identity.p12" -k "$LOGIN_KC" -P lgcontroller -A -T /usr/bin/codesign \
    && import_ok=true
fi

echo ""
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "✅ 完成。证书已就绪，./build.sh 会自动用「$NAME」签名。"
  echo ""
  echo "接下来（仅这一次）："
  echo "  1) tccutil reset Accessibility com.toyzcool.LGController   # 清掉旧的 ad-hoc 授权"
  echo "  2) ./build.sh                                          # 用新证书重建并安装到 /Applications"
  echo "  3) 到 系统设置→隐私与安全性→辅助功能 勾选 LGController   # 之后重建不用再授权"
else
  echo "⚠️ 未检测到证书「$NAME」，创建失败。请把上面的输出发我。"
  exit 1
fi
