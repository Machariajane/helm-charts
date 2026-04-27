#!/usr/bin/env bash

set -o pipefail

{{- include "tempest-base.function_start_tempest_tests" . }}

function is_tempest_network_name() {
    local name="$1"

    [[ "$name" =~ ^neutron-tempest ]] && return 1
    [[ "$name" =~ locust ]] && return 1

    [[ "$name" =~ ^tempest- ]] && return 0
    [[ "$name" == "tempest_test" ]] && return 0

    return 1
}

function cleanup_ports_and_networks() {
    openstack network list -f value -c ID -c Name | while read -r net_id net_name; do

        if ! is_tempest_network_name "$net_name"; then
            continue
        fi

        echo "Processing network: $net_name ($net_id)"

        local router_ports=$(openstack port list --network "$net_id" --device-owner network:router_interface -f value -c ID)
        for port_id in $router_ports; do
            local router_id=$(openstack port show "$port_id" -f value -c device_id)
            echo "Removing interface $port_id from router $router_id"
            openstack router remove port "$router_id" "$port_id" || true
        done

        for port_id in $(openstack port list --network "$net_id" -f value -c ID); do
            echo "Deleting port $port_id"
            openstack port set "$port_id" --disable --no-fixed-ip || true
            openstack port delete "$port_id" || true
        done

        for subnet_id in $(openstack subnet list --network "$net_id" -f value -c ID); do
            echo "Deleting subnet $subnet_id"
            openstack subnet delete "$subnet_id" || true
        done

        echo "Deleting network $net_name"
        openstack network delete "$net_id" || true
    done
}

function cleanup_routers() {
    openstack router list -f value -c ID -c Name | while read -r router_id router_name; do
        if [[ "$router_name" =~ tempest ]]; then
            echo "Cleaning up router $router_name"
            openstack router unset --external-gateway "$router_id" || true

            for port_id in $(openstack port list --router "$router_id" -f value -c ID); do
                openstack router remove port "$router_id" "$port_id" || true
            done

            openstack router delete "$router_id" || true
        fi
    done
}

function cleanup_security_groups() {
    openstack security group list -f value -c ID -c Name | while read -r sg_id sg_name; do
        [[ "$sg_name" == "default" ]] && continue
        [[ ! "$sg_name" =~ tempest ]] && continue

        echo "Deleting security group $sg_name"
        openstack security group delete "$sg_id" || true
    done
}

function cleanup_fips() {
    for fip in $(openstack floating ip list -f value -c ID); do
        echo "Deleting FIP $fip"
        openstack floating ip delete "$fip" || true
    done
}

function cleanup_project_neutron() {
    cleanup_fips
    cleanup_ports_and_networks
    cleanup_routers
    cleanup_security_groups

    for res in "address group" "subnet pool" "address scope"; do
        openstack $res list -f value -c ID -c Name | while read id name; do
            if [[ "$name" =~ tempest ]]; then
                echo "Deleting $res $name"
                openstack $res delete "$id" || true
            fi
        done
    done
}

function cleanup_tempest_leftovers() {
    echo "Starting Neutron-only cleanup"

    for i in $(seq 1 10); do
        export OS_USERNAME="neutron-tempestuser$i"
        export OS_PROJECT_NAME="neutron-tempest$i"
        export OS_TENANT_NAME="neutron-tempest$i"
        cleanup_project_neutron
    done

    for i in $(seq 1 4); do
        export OS_USERNAME="neutron-tempestadmin$i"
        export OS_PROJECT_NAME="neutron-tempest-admin$i"
        export OS_TENANT_NAME="neutron-tempest-admin$i"
        cleanup_project_neutron
    done

    export OS_USERNAME="neutron-tempestadmin1"
    export OS_PROJECT_NAME="neutron-tempest-admin1"
    echo "Performing final admin sweep..."
    cleanup_project_neutron
}

{{- include "tempest-base.function_main" . }}

main