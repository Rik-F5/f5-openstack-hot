#!/bin/bash
echo '******STARTING PRE-ONBOARD******'
remoteHostsNames="__remote_hosts_names__"
remoteHostsIps="__remote_hosts_ips__"
verifyHashOverride="__verify_hash_override__"
verifyCloudlibsOs="__verify_cloudlibs_os__"
wcNotifyOptions="__wc_notify_options__"
hosts=""
hostsIps=""
hostsCount=""
msg=""
stat=""
function set_vars() {
    if [[ "$verifyHashOverride" != "" && "$verifyHashOverride" != "None" ]]; then
        curl ${verifyHashOverride} > /config/verifyHash
    fi
    if [[ "$remoteHostsNames" != "[None]" && "$remoteHostsIps" != "[None]" ]]; then
        remoteHosts="${remoteHostsNames:1:${#remoteHostsNames}-2}"
        remoteHostsIps="${remoteHostsIps:1:${#remoteHostsIps}-2}"
        OIFS="$IFS"
        IFS=', '
        read -r -a hosts <<< "${remoteHosts}"
        read -r -a hostsIps <<< "${remoteHostsIps}"
        IFS="$OIFS"
        hostsCount=${#hosts[@]}
    else
        hostsCount=0
    fi
}
function check_mcpd_status() {
    echo 'Starting MCP status check'
    checks=0
    while [ $checks -lt 120 ]; do echo checking mcpd
        if tmsh -a show sys mcp-state field-fmt | grep -q running; then
            echo mcpd ready
            break
        fi
        echo mcpd not ready yet
        let checks=checks+1
        sleep 10
    done
}
function verify_files() {
    echo 'loading verifyHash script'
    if ! tmsh load sys config merge file /config/verifyHash; then
        echo cannot validate signature of /config/verifyHash
        msg="Unable to validate verifyHash."
    fi
    echo 'loaded verifyHash'
    declare -a filesToVerify=("/config/cloud/openstack/f5-cloud-libs.tar.gz")
	if [ "$verifyCloudlibsOs" == "True" ] ; then
	    filesToVerify+=("/config/cloud/openstack/f5-cloud-libs-openstack.tar.gz")
	fi
    for fileToVerify in "${filesToVerify[@]}"
    do
        echo verifying "$fileToVerify"
        if ! tmsh run cli script verifyHash "$fileToVerify"; then
            echo "$fileToVerify" is not valid
            msg="Unable to verify one or more files."
        fi
        echo verified "$fileToVerify"
    done
}
function prep_cloud_libs() {
    if [[ "$msg" == "" ]]; then
        echo 'Preparing CloudLibs'
        mkdir -p /config/cloud/openstack/node_modules/@f5devcentral
        tar xvfz /config/cloud/openstack/f5-cloud-libs.tar.gz -C /config/cloud/openstack/node_modules/@f5devcentral
		if [ "$verifyCloudlibsOs" == "True" ] ; then
        	tar --warning=no-unknown-keyword -zxf /config/cloud/openstack/f5-cloud-libs-openstack.tar.gz -C /config/cloud/openstack/node_modules/@f5devcentral > /dev/null
        fi
		touch /config/cloud/openstack/cloudLibsReady
    fi
}
function set_remote_hosts() {
    if [[ $hostsCount -gt 0 ]]; then
        local counter=0
        while [[ $counter -lt $hostsCount ]]; do
            host=${hosts[$counter]}
            hostIp=${hostsIps[$counter]}
            set_remote_host
            let counter+=1;
        done
    fi
}
function set_remote_host() {
    tmsh modify sys global-settings remote-host add { "$host" { hostname "$host" addr "$hostIp" } }
}
function configure_ssh_key() {
    echo 'Configuring access to cloud-init data'
    useConfigDrive="__use_config_drive__"
    configDriveSrc=$(blkid -t LABEL="config-2" -odevice)
    configDriveDest="/mnt/config"
    if [[ "$useConfigDrive" == "True" ]]; then
        echo 'Configuring Cloud-init ConfigDrive'
        mkdir -p $configDriveDest
        if mount "$configDriveSrc" $configDriveDest; then
            echo 'Adding SSH Key from Config Drive'
            if sshKey=$(python -c 'import sys, json; print json.load(sys.stdin)["public_keys"]["__ssh_key_name__"]' <"$configDriveDest"/openstack/latest/meta_data.json) ; then
                echo "$sshKey" >> /root/.ssh/authorized_keys
            else
                msg="Pre-onboard failed: Unable to inject SSH key from config drive."
                echo "$msg"
            fi
        else
            msg="Pre-onboard failed: Unable to mount config drive."
            echo "$msg"
        fi
    else
        echo 'Adding SSH Key from Metadata service'
        declare -r tempKey="/config/cloud/openstack/os-ssh-key.pub"
        if curl http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key -s -f --retry 5   --retry-max-time 300 --retry-delay 10 -o $tempKey ; then
            (head -n1 $tempKey) >> /root/.ssh/authorized_keys
            rm $tempKey
        else
            msg="Pre-onboard failed: Unable to inject SSH key from metadata service."
            stat="FAILURE"
            echo "$msg"
        fi
    fi
}
function check_strace() {
    if [ -z $(pidof strace) ]; then
        nohup sh -c 'while true; do if [ -s /service/restjavad/supervise/pid ] ; then setsid strace -p $(cat /service/restjavad/supervise/pid) -o /shared/tmp/restjavad-strace.txt -f -s 1024 -v -tt ; break; fi ; done > /dev/null 2>&1' &>/dev/null < /dev/null & #debug
    fi
}
function check_restjavad_status() {
    for i in $(seq 3); do
        echo "Checking status of restjavad..."
        if [ $(curl -sk --user admin:admin -o /dev/null -w "%{http_code}" https://localhost/mgmt/tm/sys/available) = "200" ]; then
            kill $(pidof strace) > /dev/null 2>&1
            rm -f /shared/tmp/restjavad-strace.txt
            echo "restjavad is running properly"
            stat="SUCCESS"
            break
        else
            stat="FAILURE"
            echo "Restarting restjavad"
            bigstart restart restjavad
            if [ -f /shared/tmp/restjavad-strace.txt ]; then
                time=$(date +%s)
                mv /shared/tmp/restjavad-strace.txt /shared/tmp/restjavad-strace_$time.out
                echo "Initial restjavad failed... Please upload /shared/tmp/restjavad-strace_$time.out to F5 support"
            fi
            if [ $i != "3" ]; then
                nohup sh -c 'while true; do if [ -s /service/restjavad/supervise/pid ] ; then setsid strace -p $(cat /service/restjavad/supervise/pid) -o /shared/tmp/restjavad-strace.txt -f -s 1024 -v -tt ; break; fi ; done > /dev/null 2>&1' &>/dev/null < /dev/null &
                sleep 60
            fi
        fi
    done
    if [[ "$stat" == "FAILURE" ]]; then
        msg="restjavad is not running properly, onboarding failed..."
        echo "$msg"
    fi
}
function send_heat_signal() {
    sleep 120
    if [[ "$msg" == "" ]]; then
        stat="SUCCESS"
        msg="Pre-onboard completed without error."
    else
        stat="FAILURE"
        msg="Last Error:$msg . See /var/log/cloud/openstack/preOnboard.log for details."
    fi
    if [ "$wcNotifyOptions" == "None" ]; then
        wcNotifyOptions=""
    else
        wcNotifyOptions=" $wcNotifyOptions"
    fi
    wc_notify --data-binary '{"status": "'"$stat"'", "reason":"'"$msg"'"}' --retry 5 --retry-max-time 300 --retry-delay 30$wcNotifyOptions
    echo "$msg"
    echo '******PRE-ONBOARD DONE******'
}
function main() {
    check_strace
    set_vars
    check_mcpd_status
    verify_files
    prep_cloud_libs
    set_remote_hosts
    configure_ssh_key
    check_restjavad_status
    send_heat_signal
}
main
