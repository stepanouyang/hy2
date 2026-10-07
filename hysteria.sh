cat << 'SCRIPT_WRAPPER' > /root/hysteria.sh
#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do SYS="$i" && [[ -n $SYS ]] && break; done
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "目前暂不支持你的VPS的操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then ${PACKAGE_UPDATE[int]}; fi
    ${PACKAGE_INSTALL[int]} curl
fi

realip(){
    ipv4=$(curl -s4m5 https://api.ip.sb/ip || curl -s4m5 https://ip.gs || echo "")
    ipv6=$(curl -s6m5 https://api.ip.sb/ip || curl -s6m5 https://ip.gs || echo "")
}

save_firewall(){
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1 && service iptables status >/dev/null 2>&1; then
        service iptables save >/dev/null 2>&1
        service ip6tables save >/dev/null 2>&1
    fi
}

clean_jump_rules(){
    # 精准剔除旧的端口转发，杜绝 iptables -F PREROUTING 破坏 Docker 容器网络
    for cmd in iptables ip6tables; do
        if command -v $cmd >/dev/null 2>&1; then
            while read -r rule; do
                [[ -n "$rule" ]] && eval "$cmd -t nat ${rule/-A/-D}" 2>/dev/null
            done < <($cmd -t nat -S PREROUTING 2>/dev/null | grep -E "\-j DNAT \-\-to\-destination :[0-9]+")
        fi
    done
    save_firewall
}

install_official_core(){
    green "正在从 Hysteria 2 官方通道获取最新内核..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) HY_ARCH="amd64" ;;
        aarch64) HY_ARCH="arm64" ;;
        s390x) HY_ARCH="s390x" ;;
        *) red "官方未提供针对此架构 ($ARCH) 的预编译文件！" && exit 1 ;;
    esac

    DOWNLOAD_SOURCES=(
        "https://download.hysteria.network/app/latest/hysteria-linux-${HY_ARCH}"
        "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
        "https://mirror.ghproxy.com/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
        "https://gh-proxy.com/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
    )

    SUCCESS=0
    for url in "${DOWNLOAD_SOURCES[@]}"; do
        green "正在连接官方通道: $url ..."
        rm -f /usr/local/bin/hysteria
        if curl -L --connect-timeout 10 -m 90 -f -o /usr/local/bin/hysteria "$url"; then
            if [[ -s "/usr/local/bin/hysteria" ]]; then
                chmod +x /usr/local/bin/hysteria
                if /usr/local/bin/hysteria version >/dev/null 2>&1 || /usr/local/bin/hysteria --version >/dev/null 2>&1; then
                    SUCCESS=1
                    break
                fi
            fi
        fi
        yellow "当前通道超时或异常，自动切换备用高可用通道..."
    done

    if [[ $SUCCESS -ne 1 ]]; then
        yellow "静态通道受阻，尝试启用官方安装脚本通道..."
        if curl -fsSL https://get.hy2.sh/ | bash -s -- --no-service; then
            if [[ -s "/usr/local/bin/hysteria" ]]; then
                chmod +x /usr/local/bin/hysteria
                SUCCESS=1
            fi
        fi
    fi

    if [[ $SUCCESS -eq 1 ]]; then
        INSTALLED_VER=$(/usr/local/bin/hysteria version 2>/dev/null | head -n 1 || /usr/local/bin/hysteria --version 2>/dev/null | head -n 1 || echo "Latest")
        green "官方最新内核部署成功！版本: $INSTALLED_VER"
    else
        red "所有官方下载源均不可达，请检查 VPS 的公网网络或 DNS！" && exit 1
    fi

    mkdir -p /etc/hysteria
    {
        echo "[Unit]"
        echo "Description=Hysteria 2 Server"
        echo "After=network.target"
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml"
        echo "WorkingDirectory=/etc/hysteria"
        echo "Environment=HYSTERIA_LOG_LEVEL=info"
        echo "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW"
        echo "AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW"
        echo "NoNewPrivileges=true"
        echo "Restart=on-failure"
        echo "RestartSec=3s"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
}

inst_cert(){
    green "Hysteria 2 协议证书申请方式如下："
    echo -e " 1. 必应自签证书 （默认）\n 2. Acme 脚本自动申请\n 3. 自定义证书路径"
    read -rp "请输入选项 [1-3]: " certInput
    
    if [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        chmod -R 777 /root && touch /root/cert.crt /root/private.key && chmod +rw /root/cert.crt /root/private.key

        if [[ -s /root/cert.crt && -s /root/private.key && -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "检测到原有域名：$domain 的证书，正在应用"
            hy_domain=$domain
        else
            realip
            read -p "请输入需要申请证书的域名：" domain
            [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
            green "已输入的域名：$domain"
            
            domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null)
            if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
                domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null)
            fi
            
            if [[ "$domainIP" != "$ipv4" && "$domainIP" != "$ipv6" ]]; then
                red "解析 IP ($domainIP) 与本机 IP ($ipv4 / $ipv6) 不匹配。"
                yellow "是否强行继续匹配申请？"
                read -p "1. 是 2. 否 [1-2]：" ipChoice
                if [[ $ipChoice != 1 ]]; then exit 1; fi
            fi

            ${PACKAGE_INSTALL[int]} curl wget sudo qrencode procps iptables-persistent netfilter-persistent socat openssl
            if [[ $SYSTEM == "CentOS" ]]; then
                ${PACKAGE_INSTALL[int]} cronie && systemctl start crond && systemctl enable crond
            else
                ${PACKAGE_INSTALL[int]} cron && systemctl start cron && systemctl enable cron
            fi
            
            curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
            source ~/.bashrc
            bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            
            if [[ -n "$ipv6" && -z "$ipv4" ]]; then
                bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
            else
                bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
            fi
            
            bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
            if [[ -s /root/cert.crt && -s /root/private.key ]]; then
                echo $domain > /root/ca.log
                sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                green "证书申请成功!"
                hy_domain=$domain
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -p "请输入公钥 crt 路径：" cert_path
        read -p "请输入密钥 key 路径：" key_path
        read -p "请输入证书域名：" domain
        hy_domain=$domain
    else
        green "使用必应自签证书"
        cert_path="/etc/hysteria/cert.crt"; key_path="/etc/hysteria/private.key"
        mkdir -p /etc/hysteria
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
        chmod 777 /etc/hysteria/cert.crt /etc/hysteria/private.key
        hy_domain="www.bing.com"
    fi
}

inst_jump(){
    green "Hysteria 2 端口使用模式配置："
    echo -e " 1. 单端口模式 (默认)\n 2. 端口跳跃模式 (抗封锁与抗 QoS 推荐)"
    read -rp "请输入选项 [1-2]: " jumpInput
    firstport=""
    endport=""

    if [[ $jumpInput == 2 ]]; then
        while true; do
            read -p "设置范围端口的起始端口 (建议 10000-65535，默认 20000)：" firstport
            [[ -z $firstport ]] && firstport=20000
            read -p "设置范围端口的末尾端口 (建议 10000-65535，默认 40000)：" endport
            [[ -z $endport ]] && endport=40000

            if [[ ! "$firstport" =~ ^[0-9]+$ ]] || [[ ! "$endport" =~ ^[0-9]+$ ]]; then
                red "端口必须为数字！"
            elif [[ $firstport -le 0 || $firstport -gt 65535 || $endport -le 0 || $endport -gt 65535 ]]; then
                red "端口范围必须在 1-65535 之间！"
            elif [[ $firstport -ge $endport ]]; then
                red "起始端口 ($firstport) 必须小于末尾端口 ($endport)！"
            elif [[ $port -ge $firstport && $port -le $endport ]]; then
                red "主监听端口 ($port) 不能包含在跳跃端口范围内，请重新调整！"
            else
                break
            fi
        done

        clean_jump_rules
        green "正在注入双栈 UDP DNAT 转发规则: $firstport:$endport -> :$port ..."
        iptables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
        ip6tables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port" 2>/dev/null || true
        save_firewall

        # 记录跳跃配置
        echo "firstport=$firstport" > /etc/hysteria/jump.conf
        echo "endport=$endport" >> /etc/hysteria/jump.conf
        green "端口跳跃规则应用成功！"
    else
        clean_jump_rules
        rm -f /etc/hysteria/jump.conf
        yellow "已选择单端口模式"
    fi
}

inst_port(){
    read -p "设置 Hysteria 2 主监听端口 [1-65535]（回车随机分配）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | grep -E ":$port$") ]]; do
        echo -e "${RED} $port 端口占用！${PLAIN}"; read -p "重新设置端口：" port
    done
    yellow "使用主监听端口：$port"
    inst_jump
}

inst_pwd(){
    read -p "设置 Hysteria 2 密码（回车随机）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "使用密码：$auth_pwd"
}

inst_site(){
    read -rp "伪装网站（去除https://）[回车默认 maimai.sega.jp]：" proxysite
    [[ -z $proxysite ]] && proxysite="maimai.sega.jp"
}

insthysteria(){
    realip
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then red "严重错误：无法获取公网 IP" && exit 1; fi

    if [[ ! ${SYSTEM} == "CentOS" ]]; then ${PACKAGE_UPDATE}; fi
    ${PACKAGE_INSTALL} curl wget sudo qrencode procps iptables-persistent netfilter-persistent

    install_official_core
    inst_cert && inst_port && inst_pwd && inst_site

    # 黄金法则：无死锁双栈原生监听配置
    {
        echo "listen: :$port"
        echo ""
        echo "tls:"
        echo "  cert: $cert_path"
        echo "  key: $key_path"
        echo ""
        echo "quic:"
        echo "  initStreamReceiveWindow: 16777216"
        echo "  maxStreamReceiveWindow: 16777216"
        echo "  initConnReceiveWindow: 33554432"
        echo "  maxConnReceiveWindow: 33554432"
        echo ""
        echo "auth:"
        echo "  type: password"
        echo "  password: $auth_pwd"
        echo ""
        echo "masquerade:"
        echo "  type: proxy"
        echo "  proxy:"
        echo "    url: https://$proxysite"
        echo "    rewriteHost: true"
    } > /etc/hysteria/config.yaml

    if [ -n "$ipv4" ]; then client_ip="$ipv4"; else client_ip="[$ipv6]"; fi

    if [[ -n "$firstport" && -n "$endport" ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port="$port"
    fi

    mkdir -p /root/hy

    # 生成通用客户端 YAML 配置文件
    {
        echo "server: $client_ip:$last_port"
        echo "auth: $auth_pwd"
        echo "tls:"
        echo "  sni: $hy_domain"
        echo "  insecure: true"
        echo "quic:"
        echo "  initStreamReceiveWindow: 16777216"
        echo "  maxStreamReceiveWindow: 16777216"
        echo "  initConnReceiveWindow: 33554432"
        echo "  maxConnReceiveWindow: 33554432"
        echo "fastOpen: true"
        echo "outbound:"
        echo "  strategy: auto"
        echo "socks5:"
        echo "  listen: 127.0.0.1:5080"
        if [[ -n "$firstport" && -n "$endport" ]]; then
            echo "transport:"
            echo "  udp:"
            echo "    hopInterval: 30s"
        fi
    } > /root/hy/hy-client.yaml

    # 生成 Clash Meta / Mihomo 配置
    {
        echo "mixed-port: 7890"
        echo "allow-lan: false"
        echo "mode: rule"
        echo "log-level: info"
        echo "ipv6: true"
        echo "dns:"
        echo "  enable: true"
        echo "  enhanced-mode: fake-ip"
        echo "  nameserver:"
        echo "    - 8.8.8.8"
        echo "    - 1.1.1.1"
        echo "proxies:"
    } > /root/hy/clash-meta.yaml

    if [ -n "$ipv4" ]; then
        {
            echo "  - name: Hysteria2-IPv4"
            echo "    type: hysteria2"
            echo "    server: $ipv4"
            echo "    port: $port"
            if [[ -n "$firstport" && -n "$endport" ]]; then
                echo "    ports: $last_port"
                echo "    hop-interval: 30"
            fi
            echo "    password: $auth_pwd"
            echo "    sni: $hy_domain"
            echo "    skip-cert-verify: true"
        } >> /root/hy/clash-meta.yaml
        echo "hysteria2://$auth_pwd@$ipv4:$last_port/?insecure=1&sni=$hy_domain#Hysteria2-IPv4" > /root/hy/url_v4.txt
        echo "hysteria2://$auth_pwd@$ipv4:$port/?insecure=1&sni=$hy_domain#Hysteria2-IPv4-NoHop" > /root/hy/url_v4_nohop.txt
    fi

    if [ -n "$ipv6" ]; then
        {
            echo "  - name: Hysteria2-IPv6"
            echo "    type: hysteria2"
            echo "    server: $ipv6"
            echo "    port: $port"
            if [[ -n "$firstport" && -n "$endport" ]]; then
                echo "    ports: $last_port"
                echo "    hop-interval: 30"
            fi
            echo "    password: $auth_pwd"
            echo "    sni: $hy_domain"
            echo "    skip-cert-verify: true"
        } >> /root/hy/clash-meta.yaml
        echo "hysteria2://$auth_pwd@[$ipv6]:$last_port/?insecure=1&sni=$hy_domain#Hysteria2-IPv6" > /root/hy/url_v6.txt
        echo "hysteria2://$auth_pwd@[$ipv6]:$port/?insecure=1&sni=$hy_domain#Hysteria2-IPv6-NoHop" > /root/hy/url_v6_nohop.txt
    fi

    # 放行本地防火墙端口
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    if [[ -n "$firstport" && -n "$endport" ]]; then
        iptables -I INPUT -p udp --dport "$firstport:$endport" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT -p udp --dport "$firstport:$endport" -j ACCEPT 2>/dev/null || true
    fi
    save_firewall

    systemctl enable hysteria-server
    systemctl restart hysteria-server
    
    if systemctl is-active --quiet hysteria-server; then
        green "Hysteria 2 双栈守护进程点火成功！"
    else
        red "服务拉起失败，请运行 systemctl status hysteria-server 查看日志" && exit 1
    fi
    showconf
}

unsthysteria(){
    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /etc/systemd/system/hysteria-server.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy
    systemctl daemon-reload
    clean_jump_rules
    green "Hysteria 2 已彻底卸载干净！"
}

hysteriaswitch(){
    yellow "请选择操作："
    echo -e " 1. 启动\n 2. 关闭\n 3. 重启"
    read -rp "[1-3]: " switchInput
    case $switchInput in
        1 ) systemctl start hysteria-server ;;
        2 ) systemctl stop hysteria-server ;;
        3 ) systemctl restart hysteria-server ;;
    esac
}

changeconf(){
    green "修改向导："
    echo -e " 1. 修改主监听端口\n 2. 重新配置端口跳跃\n 3. 修改密码"
    read -p " 请选择 [1-3]：" confAnswer
    if [ "$confAnswer" == "1" ]; then
        oldport=$(cat /etc/hysteria/config.yaml | grep -E "listen:" | awk -F ":" '{print $NF}' | tr -d '"' | tr -d ' ')
        read -p "请输入全新主监听端口: " port
        sed -i "s#:$oldport#:$port#g" /etc/hysteria/config.yaml
        if [[ -f /etc/hysteria/jump.conf ]]; then
            source /etc/hysteria/jump.conf
            clean_jump_rules
            iptables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
            ip6tables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port" 2>/dev/null || true
            save_firewall
        fi
        systemctl restart hysteria-server && green "主监听端口修改完毕！"
    elif [ "$confAnswer" == "2" ]; then
        port=$(cat /etc/hysteria/config.yaml | grep -E "listen:" | awk -F ":" '{print $NF}' | tr -d '"' | tr -d ' ')
        inst_jump
        green "端口跳跃规则已更新！建议执行选项 1 重新生成客户端配置以同步更改。"
    elif [ "$confAnswer" == "3" ]; then
        read -p "请输入全新密码: " passwd
        sed -i "s/password:.*/password: \"$passwd\"/g" /etc/hysteria/config.yaml
        systemctl restart hysteria-server && green "密码修改完毕！"
    fi
}

showconf(){
    realip
    echo "======================================================================================"
    green "Hysteria 2 原生双栈环境完全体配置生成成功"
    if [ -f "/etc/hysteria/jump.conf" ]; then
        source /etc/hysteria/jump.conf
        yellow "当前运行模式: 端口跳跃模式 (范围: $firstport - $endport)"
    else
        yellow "当前运行模式: 单端口模式"
    fi
    echo "======================================================================================"

    if [ -f "/root/hy/hy-client.yaml" ]; then
        yellow "通用 YAML 客户端文件 (/root/hy/hy-client.yaml):"
        cat /root/hy/hy-client.yaml
    fi
    echo "--------------------------------------------------------------------------------------"
    if [ -f "/root/hy/clash-meta.yaml" ]; then
        yellow "Clash Meta 配置文件已生成至: /root/hy/clash-meta.yaml"
    fi
    
    echo ""
    yellow "🛠️ 请根据本地网络环境，按需选择下方节点链接导入："
    echo "--------------------------------------------------------------------------------------"
    if [ -f "/root/hy/url_v4.txt" ] && [ -n "$ipv4" ]; then
        green "【IPv4 跳跃节点链接】:"
        cat /root/hy/url_v4.txt
        yellow "【IPv4 备用单端口链接】:"
        cat /root/hy/url_v4_nohop.txt
        echo "--------------------------------------------------------------------------------------"
    fi
    if [ -f "/root/hy/url_v6.txt" ] && [ -n "$ipv6" ]; then
        green "【IPv6 跳跃节点链接】:"
        cat /root/hy/url_v6.txt
        yellow "【IPv6 备用单端口链接】:"
        cat /root/hy/url_v6_nohop.txt
        echo "--------------------------------------------------------------------------------------"
    fi
    echo "======================================================================================"
}

update_core(){
    green "正在准备热更新 Hysteria 2 内核..."
    install_official_core
    systemctl restart hysteria-server
    if systemctl is-active --quiet hysteria-server; then
        green "Hysteria 2 官方最新内核已热更新并重启完毕！"
    else
        red "服务重启失败，请检查运行状态！"
    fi
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#           ${GREEN}Hysteria 2 工业级完全体部署脚本${PLAIN}                 #"
    echo -e "#           ${YELLOW}数据源: apernet/hysteria 官方直连${PLAIN}               #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装/覆盖 Hysteria 2 (原生双栈 + 端口跳跃)"
    echo -e " ${GREEN}2.${PLAIN} ${RED}物理卸载 Hysteria 2${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} 开启、关闭、重启控制器"
    echo -e " ${GREEN}4.${PLAIN} 快捷微调端口、跳跃规则或密码"
    echo -e " ${GREEN}5.${PLAIN} 打印当前的双栈客户端配置"
    echo " -------------"
    echo -e " ${GREEN}6.${PLAIN} 同步更新 Hysteria 2 官方最新内核"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo ""
    read -rp "选择: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        6 ) update_core ;;
        * ) exit 0 ;;
    esac
}

menu
SCRIPT_WRAPPER

chmod +x /root/hysteria.sh
bash /root/hysteria.sh
