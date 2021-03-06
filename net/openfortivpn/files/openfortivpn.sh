#!/bin/sh
. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

append_args() {
        while [ $# -gt 0 ]; do
                append cmdline "'${1//\'/\'\\\'\'}'"
                shift
        done
}

proto_openfortivpn_init_config() {
        proto_config_add_string "server"
        proto_config_add_int "port"
        proto_config_add_string "iface_name"
        proto_config_add_string "local_ip"
        proto_config_add_string "username"
        proto_config_add_string "password"
        proto_config_add_string "trusted_cert"
        proto_config_add_string "remote_status_check"	
        proto_config_add_int "set_dns"
        proto_config_add_int "pppd_use_peerdns"
        proto_config_add_int "peerdns"
        proto_config_add_int "metric"
        no_device=1
        available=1
}

proto_openfortivpn_setup() {
        local config="$1"
        local msg

        json_get_vars host server port iface_name local_ip username password trusted_cert \
	              remote_status_check set_dns pppd_use_peerdns metric

        ifname="vpn-$config"


        [ -n "$iface_name" ] && {
            json_load "$(ifstatus $iface_name)"
            json_get_var iface_device_name l3_device
            json_get_var iface_device_up up
        }

        [ "$iface_device_up" -eq 1 ] || {
            msg="$iface_name is not up $iface_device_up"
            logger -t "openfortivpn" "$config: $msg"
            proto_notify_error "$config" "$msg"
            proto_block_restart "$config"
            exit 1
        }

        server_ip=$(resolveip -t 10 "$server")

        [ $? -eq 0 ] || {
            msg="$config: failed to resolve server ip for $server"
            logger -t "openfortivpn" "$msg"
            sleep 10
            proto_notify_error "$config" "$msg"
            proto_setup_failed "$config"
            exit 1
        }

	[ "$remote_status_check" = "curl" ] && {
            curl -k --head -s --connect-timeout 10 ${iface_name:+--interface} $iface_device_name https://$server_ip > /dev/null || {
		msg="failed to reach https://${server_ip}${iface_name:+ on $iface_device_name}"
		logger -t "openfortivpn" "$config: $msg"
		sleep 10
		proto_notify_error "$config" "$msg"
		proto_setup_failed "$config"
		exit 1
	    }
	}
	[ "$remote_status_check" = "ping" ]  && {
            ping ${iface_name:+-I} $iface_device_name -c 1 -w 10 $server_ip > /dev/null 2>&1 || {
                msg="$config: failed to ping $server_ip on $iface_device_name"
		logger -t "openfortvpn" "$config: $msg"
                sleep 10
                proto_notify_error "$config" "failed to ping $server_ip on $iface_device_name"
                proto_setup_failed "$config"
                exit 1
            }
	}

        for ip in $(resolveip -t 10 "$server"); do
                logger -p 6 -t "openfortivpn" "$config: adding host dependency for $ip on $iface_name at $config"
                proto_add_host_dependency "$config" "$ip" "$iface_name"
        done



        [ -n "$port" ] && port=":$port"

        append_args "$server$port" --pppd-ifname="$ifname" --use-syslog  -c /dev/null
        append_args "--set-dns=$set_dns"
        append_args "--no-routes"
        append_args "--pppd-use-peerdns=$pppd_use_peerdns"

        [ -n "$iface_name" ] && {
            append_args "--ifname=$iface_device_name"
        }

        [ -n "$trusted_cert" ] && append_args "--trusted-cert=$trusted_cert"
        [ -n "$username" ] && append_args -u "$username"
        [ -n "$password" ] && {
                umask 077
                mkdir -p /var/etc
                pwfile="/var/etc/openfortivpn/$config.passwd"
                echo "$password" > "$pwfile"
        }

        [ -n "$local_ip" ] || local_ip=192.0.2.1
        [ -e '/etc/ppp/peers' ] || mkdir -p '/etc/ppp/peers'
        [ -e '/etc/ppp/peers/openfortivpn' ] || {
            ln -s -T '/var/etc/openfortivpn/peers' '/etc/ppp/peers/openfortivpn'
            mkdir -p '/var/etc/openfortivpn/peers'
        }

        callfile="/var/etc/openfortivpn/peers/$config"
        echo "115200
:$local_ip
noipdefault
noaccomp
noauth
default-asyncmap
nopcomp
receive-all
defaultroute
nodetach
ipparam $config
lcp-max-configure 40
ip-up-script /lib/netifd/ppp-up
ip-down-script /lib/netifd/ppp-down
mru 1354"  > $callfile
        append_args "--pppd-call=openfortivpn/$config"

        proto_export INTERFACE="$ifname"
        logger -p 6 -t openfortivpn "$config: executing 'openfortivpn $cmdline'"

        eval "proto_run_command '$config' /usr/sbin/openfortivpn-wrapper '$pwfile' $cmdline"

}

proto_openfortivpn_teardown() {
        local config="$1"

        pwfile="/var/etc/openfortivpn/$config.passwd"
        callfile="/var/etc/openfortivpn/peers/$config"

        rm -f $pwfile
        rm -f $callfile
        proto_kill_command "$config" 2
}

add_protocol openfortivpn
