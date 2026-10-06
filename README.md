一键生成证书及自动续签：

curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

一条命令即可停止并删除自动续期任务，同时保留现有证书：

systemctl disable --now acme-cert-renew.timer 2>/dev/null; rm -f /etc/systemd/system/acme-cert-renew.timer /etc/systemd/system/acme-cert-renew.service /root/acme-cert-renew; systemctl daemon-reload; systemctl reset-failed

执行后可以检查：

systemctl list-timers --all | grep acme-cert-renew

没有输出 = 自动续期已经彻底关闭
