#!/bin/bash

# Script directory
SRC=$(realpath "${BASH_SOURCE[0]}")
DIR="$(dirname "$SRC")"

# Assign inputs to variables
authEmail=$(grep --perl-regexp --only-matching '"Auth Email":\s*?"\K[^"\s]*' "$DIR/api.config")
authKey=$(grep --perl-regexp --only-matching '"Auth Key":\s*?"\K[^"\s]*' "$DIR/api.config")
accountID=$(grep --perl-regexp --only-matching '"Account ID":\s*?"\K[^"\s]*' "$DIR/api.config")
parentDomain=$(grep --perl-regexp --only-matching '"Parent Domain":\s*?"\K[^"\s]*' "$DIR/api.config")
parentDNSEnable=$(grep --perl-regexp --only-matching '"Parent DNS Enabled":\s*?"\K[^"\s]*' "$DIR/api.config")

function getZoneID {
    # getZoneID takes a domain name and finds the domain ID for it.
    zoneID=$(curl -X GET "https://api.cloudflare.com/client/v4/zones?name=$1&account.id=$accountID"\
        -H "X-Auth-Email: $authEmail"\
        -H "X-Auth-Key: $authKey"\
        -H "Content-Type: application/json"\
        | grep --perl-regexp --only-matching '(?<="id":")[^"]*' | head -1) 
}
function onboardZone {
    # onboardZone runs most functions below to setup a new zone and optionally create a subdomain.
    if [ "$parentDNSEnable" = "true" ];then
        createSubdomain "$1"
        echo -e "\nCreateSubdomain $1 finished. Check JSON output for errors."
    fi
    # domainOutput=$(createZone "$1" | grep --perl-regexp --only-matching '(?<="id":")[^"]*' | head -1)
    createZone "$1" | grep --perl-regexp --only-matching '(?<="id":")[^"]*' | head -1
    setZone "$1"
}
# Onboard Zone functions. Called from "onboardZone".
function createSubdomain {
    getZoneID "$parentDomain"
    subdomainName="${1//./}" # Removes '.'
    curl -X POST "https://api.cloudflare.com/client/v4/zones/$zoneID/dns_records"\
        -H "X-Auth-Email: $authEmail"\
        -H "X-Auth-Key: $authKey"\
        -H "Content-Type: application/json"\
        --data "{\"type\":\"CNAME\",\"name\":\"$subdomainName\",\"content\":\"$parentDomain\",\"ttl\":120,\"proxied\":true}"
    echo -e "\nParent zone $parentDomain contains CNAME $subdomainName to $parentDomain..."
}
function createZone {
    # Creates zone $1. Example: "createZone example.com" creates example.com
    curl -X POST "https://api.cloudflare.com/client/v4/zones"\
        -H "X-Auth-Email: $authEmail"\
        -H "X-Auth-Key: $authKey"\
        -H "Content-Type: application/json"\
        --silent\
        --data "{\"name\":\"$1\",\"account\":{\"id\":\"$accountID\"},\"jump_start\":true,\"type\":\"full\"}"
    echo -e "\nZone $1 exists as $zoneID..."
}
function setZone {
    # Configures zone $1 with common settings, like always use HTTPS. Example: "setZone example.com" creates example.com
    getZoneID "$1"
    #Note: Below automatic Wordpress platform optimization requires cloudfare paid subscription and cloudfare plugin
    # curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/automatic_platform_optimization" \
    #     -H "X-Auth-Email: $authEmail" \
    #     -H "X-Auth-Key: $authKey" \
    #     -H "Content-Type: application/json" \
    #     --data "{\"value\":{\"enabled\":true,\"cf\":true,\"wordpress\":true,\"wp_plugin\":false,\"hostnames\":[\"www.$1\",\"$1],\"cache_by_device_type\":false}}"
    curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/ssl" \
        -H "X-Auth-Email: $authEmail" \
        -H "X-Auth-Key: $authKey" \
        -H "Content-Type: application/json" \
        --data '{"value":"full"}'
    curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/always_use_https"\
        -H "X-Auth-Email: $authEmail"\
        -H "X-Auth-Key: $authKey"\
        -H "Content-Type: application/json"\
        --data '{"value":"on"}'
    curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/brotli" \
        -H "X-Auth-Email: $authEmail"\
        -H "X-Auth-Key: $authKey"\
        -H "Content-Type: application/json"\
        --data '{"value":"on"}'
    if [ "$parentDNSEnable" = "true" ];then
        curl -X POST "https://api.cloudflare.com/client/v4/zones/$zoneID/dns_records"\
            -H "X-Auth-Email: $authEmail"\
            -H "X-Auth-Key: $authKey"\
            -H "Content-Type: application/json"\
            --data "{\"type\":\"CNAME\",\"name\":\"@\",\"content\":\"$parentDomain\",\"ttl\":120,\"proxied\":true}"
        echo -e "\nZone $1 contains CNAME root (@) to $parentDomain..."
    fi
    echo -e "\nZone $1 set complete. Check JSON output for errors."
}

# A la carte functions. Run as needed.
## devMode disables the cache and automatically turns off after 3 hours. Example: "devMode example.com"
function devModeOn {
    getZoneID "$1"
    curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/development_mode" \
     -H "X-Auth-Email: $authEmail" \
     -H "X-Auth-Key: $authKey" \
     -H "Content-Type: application/json" \
     --data '{"value":"on"}'
    echo -e "\ndevModOn finished for $1"
}
function devModeOff {
    getZoneID "$1"
    curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$1/settings/development_mode" \
     -H "X-Auth-Email: $authEmail" \
     -H "X-Auth-Key: $authKey" \
     -H "Content-Type: application/json" \
     --data '{"value":"off"}'
    echo -e "\ndevModOff finished for $1"
}
## deleteZone deletes the specified zone. Example: "deleteZone example.com"
function deleteZone {
    getZoneID "$1"
    echo -e "\nDeleting $1 with ID $zoneID"
    curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$zoneID"\
        -H "X-Auth-Email: $authEmail"\
        -H "X-Auth-Key: $authKey"\
        -H "Content-Type: application/json"
    echo -e "\ndeleteZone finished for $1"
}