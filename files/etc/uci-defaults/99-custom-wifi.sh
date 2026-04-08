#!/bin/sh
# 此脚本会在系统首次启动时运行，用于生成最终的无线配置

# 等待无线配置生成完毕
sleep 2

# 1. 修改 SSID (使用 uci 命令，安全且准确)
uci set wireless.@wifi-iface[0].ssid='铁哥中继器-2.4G'
uci set wireless.@wifi-iface[1].ssid='铁哥中继器-5G'

# 2. 配置 2.4G 射频 (radio0)
# 设置信道为自动
uci set wireless.radio0.channel='auto'
# 强制开启 40MHz 并锁定 (noscan=1)
uci set wireless.radio0.noscan='1'
# 设置为 802.11ax (Wi-Fi 6) 40MHz 模式
uci set wireless.radio0.htmode='HE40'
# 开启 256-QAM 等相关特性 (通过 LDPC 开启)
uci set wireless.radio0.ldpc='1'
# 开启 MU-MIMO
uci set wireless.radio0.mu_beamformer='1'

# 3. 确保 5G 射频 (radio1) 配置正确 (撤销可能的错误设置)
# 删除可能被错误设置的参数
uci del wireless.radio1.noscan 2>/dev/null
# 请根据你之前的配置选择其一，HE160代表开启160MHz
uci set wireless.radio1.htmode='HE80'
# 开启 MU-MIMO (5G)
uci set wireless.radio1.mu_beamformer='1'
# 提交所有更改
uci commit wireless

# 重启网络服务使配置生效
/etc/init.d/network restart

exit 0
