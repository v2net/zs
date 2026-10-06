首次申请：

curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s \
<DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

示例：

curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s \
node.example.com /etc/node 99.cer 99.key

功能：

1. 首次申请 Let's Encrypt 证书
2. HTTP-01 / TCP 80 验证
3. 持久化 lego ACME 状态
4. 自动安装 systemd 定时续期
5. 每天检查证书
6. 剩余 30 天以内自动续期
7. 续期成功后覆盖目标证书和私钥
8. 验证证书与私钥匹配
9. 确认真正换证后自动重启 VPS

一键生成证书及自动续签：

curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

一条命令即可停止并删除自动续期任务，同时保留现有证书：

systemctl disable --now acme-cert-renew.timer 2>/dev/null; rm -f /etc/systemd/system/acme-cert-renew.timer /etc/systemd/system/acme-cert-renew.service /root/acme-cert-renew; systemctl daemon-reload; systemctl reset-failed

执行后可以检查：

systemctl list-timers --all | grep acme-cert-renew

没有输出 = 自动续期已经彻底关闭
