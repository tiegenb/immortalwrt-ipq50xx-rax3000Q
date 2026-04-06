#!/bin/sh

append DRIVERS "mac80211"

lookup_phy() {
	[ -n "$phy" ] && {
		[ -d /sys/class/ieee80211/$phy ] && return
	}
	local devpath
	config_get devpath "$device" path
	[ -n "$devpath" ] && {
		phy="$(iwinfo nl80211 phyname "path=$devpath")"
		[ -n "$phy" ] && return
	}

	local macaddr="$(config_get "$device" macaddr | tr 'A-Z' 'a-z')"
	[ -n "$macaddr" ] && {
		for _phy in /sys/class/ieee80211/*; do
			[ -e "$_phy" ] || continue

			[ "$macaddr" = "$(cat ${_phy}/macaddress)" ] || continue
			phy="${_phy##*/}"
			return
		done
	}
	phy=
	return
}

find_mac80211_phy() {
	local device="$1"

	config_get phy "$device" phy
	lookup_phy
	[ -n "$phy" -a -d "/sys/class/ieee80211/$phy" ] || {
		echo "PHY for wifi device $1 not found"
		return 1
	}
	config_set "$device" phy "$phy"

	config_get macaddr "$device" macaddr
	[ -z "$macaddr" ] && {
		config_set "$device" macaddr "$(cat /sys/class/ieee80211/${phy}/macaddress)"
	}

	return 0
}

check_mac80211_device() {
	config_get phy "$1" phy
	[ -z "$phy" ] && {
		find_mac80211_phy "$1" >/dev/null || return 0
		config_get phy "$1" phy
	}
	[ "$phy" = "$dev" ] && found=1
}


__get_band_defaults() {
	local phy="$1"

	( iw phy "$phy" info; echo ) | awk '
BEGIN {
        bands = ""
}

($1 == "Band" || $1 == "") && band {
        if (channel) {
		mode="NOHT"
		if (ht) mode="HT20"
		if (vht && band != "1:") mode="VHT80"
		if (he) mode="HE80"
		if (he && band == "1:") mode="HE20"
                sub("\\[", "", channel)
                sub("\\]", "", channel)
                bands = bands band channel ":" mode " "
        }
        band=""
}

$1 == "Band" {
        band = $2
        channel = ""
	vht = ""
	ht = ""
	he = ""
}

$0 ~ "Capabilities:" {
	ht=1
}

$0 ~ "VHT Capabilities" {
	vht=1
}

$0 ~ "HE Iftypes" {
	he=1
}

$1 == "*" && $3 == "MHz" && $0 !~ /disabled/ && band && !channel {
        channel = $4
}

END {
        print bands
}'
}

get_band_defaults() {
	local phy="$1"

	for c in $(__get_band_defaults "$phy"); do
		local band="${c%%:*}"
		c="${c#*:}"
		local chan="${c%%:*}"
		c="${c#*:}"
		local mode="${c%%:*}"

		case "$band" in
			1) band=2g;;
			2) band=5g;;
			3) band=60g;;
			4) band=6g;;
			*) band="";;
		esac

		[ -n "$band" ] || continue
		[ -n "$mode_band" -a "$band" = "6g" ] && return

		mode_band="$band"
		channel="$chan"
		htmode="$mode"
	done
}

# 启用 MU-MIMO 的函数
enable_mu_mimo() {
	local phy="$1"
	# 尝试启用 MU-MIMO（如果硬件支持）
	iw "$phy" set antenna_gain 0 2>/dev/null
	# 某些驱动通过 debugfs 启用 MU-MIMO
	if [ -d "/sys/kernel/debug/ieee80211/$phy" ]; then
		echo 1 > "/sys/kernel/debug/ieee80211/$phy/mu_mimo" 2>/dev/null
	fi
}

detect_mac80211() {
	devidx=0
	config_load wireless
	while :; do
		config_get type "radio$devidx" type
		[ -n "$type" ] || break
		devidx=$(($devidx + 1))
	done

	for _dev in /sys/class/ieee80211/*; do
		[ -e "$_dev" ] || continue

		dev="${_dev##*/}"

		found=0
		config_foreach check_mac80211_device wifi-device
		[ "$found" -gt 0 ] && continue

		mode_band=""
		channel=""
		htmode=""
		ht_capab=""

		get_band_defaults "$dev"

		path="$(iwinfo nl80211 path "$dev")"
		if [ -n "$path" ]; then
			dev_id="set wireless.radio${devidx}.path='$path'"
		else
			dev_id="set wireless.radio${devidx}.macaddr=$(cat /sys/class/ieee80211/${dev}/macaddress)"
		fi

		# 根据频段设置不同的 SSID
		if [ "$mode_band" = "2g" ]; then
			ssid_name="铁哥中继器-2.4G"
			fixed_channel="6"
			htmode="HT40"
			txpower="18"
		else
			ssid_name="铁哥中继器-5G"
			# 5G 保持驱动自动检测的所有配置，不做任何修改
			fixed_channel=""
			txpower=""
			# 注意：不修改 channel 和 htmode，保持驱动检测到的值
		fi

		# 构建 UCI 配置
		uci -q batch <<-EOF
			set wireless.radio${devidx}=wifi-device
			set wireless.radio${devidx}.type=mac80211
			${dev_id}
			set wireless.radio${devidx}.country=CN
			set wireless.radio${devidx}.disabled=0
EOF

		# 设置信道（2.4G 固定为 6，5G 保持驱动检测值）
		if [ -n "$fixed_channel" ]; then
			uci set wireless.radio${devidx}.channel="$fixed_channel"
		else
			# 5G：完全使用驱动自动检测的信道
			[ -n "$channel" ] && uci set wireless.radio${devidx}.channel="$channel"
		fi

		# 设置频段
		uci set wireless.radio${devidx}.band="$mode_band"
		
		# 设置 HT 模式（2.4G 强制 HT40，5G 保持驱动检测值）
		if [ "$mode_band" = "2g" ]; then
			uci set wireless.radio${devidx}.htmode="$htmode"
		else
			# 5G：使用驱动自动检测的 htmode
			[ -n "$htmode" ] && uci set wireless.radio${devidx}.htmode="$htmode"
		fi

		# 设置功率（仅 2.4G）
		if [ -n "$txpower" ]; then
			uci set wireless.radio${devidx}.txpower="$txpower"
		fi

		uci -q batch <<-EOF
			set wireless.default_radio${devidx}=wifi-iface
			set wireless.default_radio${devidx}.device=radio${devidx}
			set wireless.default_radio${devidx}.network=lan
			set wireless.default_radio${devidx}.mode=ap
			set wireless.default_radio${devidx}.ssid="$ssid_name"
			set wireless.default_radio${devidx}.encryption=none
EOF

		uci -q commit wireless

		# 启用 MU-MIMO（所有频段都启用）
		enable_mu_mimo "$dev"

		devidx=$(($devidx + 1))
	done
}
