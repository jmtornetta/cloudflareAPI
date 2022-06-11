#!/bin/bash
# Author: Jon Tornetta https://github.com/jmtornetta
# About: A library of functions which use Cloudflare's API to speed up DNS onboarding and management. Create zones, set DNS records, and edit properties from your terminal or program.  
start() {
    set -Eeuo pipefail
    declare -r DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
    declare -r SCRIPT=$(basename "${BASH_SOURCE[0]}") # script name
    declare -r nSCRIPT=${SCRIPT%.*} # script name without extension (for log)
    declare -r TODAY=$(date +"%Y%m%d")
    declare -r LOG="/tmp/$TODAY-$nSCRIPT.log"
    cd "$DIR" # ensure in this function's directory

    declare -r _command="${1:-}" # store first argument as the command function to invoke
    shift # removes first argument (function) from argument list

    die() {
        declare -r err="$1"
        declare -ir code="${2-1}" # default exit status 1
        printf >&2 "%s\n" "#~~~~ ERROR ~~~~#" "$err"
        exit "$code"
    }
    msg() {
        # puts 'printf' delim second, assigns default, and redirects to stderr so only shows in console/log (not script output)
        # shellcheck disable=SC2059
        if [[ "${silent:-}" == 1 ]]; then
            return 0
        elif [[ "$1" =~ (%s|%d|%c|%x|%f|%b) ]]; then
            printf >&2 "$1" "${@:2}"
        else
            printf >&2 "\n%s\n" "${@}" # two line breaks is better for messages following user-input prompts
        fi
    }

    body() {
        #~~~ BEGIN SCRIPT ~~~#
        #~~~~ Build vars from config file ~~~~#
        declare -r authEmail=$(grep --perl-regexp --only-matching '"Auth Email":\s*?"\K[^"\s]*' "$DIR/api.config")
        declare -r authKey=$(grep --perl-regexp --only-matching '"Auth Key":\s*?"\K[^"\s]*' "$DIR/api.config")
        declare -r accountID=$(grep --perl-regexp --only-matching '"Account ID":\s*?"\K[^"\s]*' "$DIR/api.config")
        declare -r parentDomain=$(grep --perl-regexp --only-matching '"Parent Domain":\s*?"\K[^"\s]*' "$DIR/api.config")
        # declare -rx parentDNSEnable=$(grep --perl-regexp --only-matching '"Parent DNS Enabled":\s*?"\K[^"\s]*' "$DIR/api.config")

        #~~~ Guard clauses ~~~~#
        [ -z "$_command" ] && die "Must provide function to call as first argument of script."

        #~~~ Modules ~~~~#
        function get_zoneId {
            # About: Finds the domain ID for a domain name.
            # Arg 1: Domain name.
            declare -r _domain="${1}"
            declare _zoneId
            set +e # So error message can be returned if _zoneId returns null

            _zoneId=$(curl --silent -X GET "https://api.cloudflare.com/client/v4/zones?name=$_domain&account.id=$accountID" \
                -H "X-Auth-Email: $authEmail" \
                -H "X-Auth-Key: $authKey" \
                -H "Content-Type: application/json" \
                | grep --perl-regexp --only-matching '(?<="id":")[^"]*' | head -1) # pipe data to grep to find the id of the zone
    
            [ -z "$_zoneId" ] && die "Could not find zone ID for '$_domain' in account."
            echo "$_zoneId" # returns the zone ID to standard output for other functions & scripts
        }
        function onboard_zone {
            # About: Setup a new zone and optionally create a subdomain. Uses below functions.
            # Arg 1: Domain name for new website/url.
            # [Arg 2]: Parent domain. Defaults to config file.

            declare -r _domain="${1}"
            declare -r _parentDomain="${2:-$parentDomain}"

            create_zone "$_domain" # Create zone for domain

            set_zone "$_domain" "$_parentDomain" # Set zone records

            # Create CNAME for new zone on parent zone, if specified.
            [ -n "$_parentDomain" ] && create_subdomain "$_domain" "$_parentDomain"
            
            msg "Onboarding for '$_domain' finished."
        }
        #~~~~ Functions for 'onboard_zone' ~~~~$
        function create_subdomain {
            # About: Create a CNAME for subdomain on a parent domain.
            # Arg 1: Sub-domain (example.com).
            # [Arg 2]: Parent domain. Defaults to config file.

            declare -r _subdomainName="${1//./}" # Removes '.' from domain name.
            declare -r _parentDomain="${2:-$parentDomain}" # Use domain defined in config as default if not provided as argument.
            declare -r _zoneID=$(get_zoneId "$_parentDomain") # Runs above function and assigns parent zone ID to new internal variable.
            declare _success

            _success=$(curl --silent -X POST "https://api.cloudflare.com/client/v4/zones/$_zoneID/dns_records" \
                -H "X-Auth-Email: $authEmail" \
                -H "X-Auth-Key: $authKey" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"CNAME\",\"name\":\"$_subdomainName\",\"content\":\"$_parentDomain\",\"ttl\":120,\"proxied\":true}" \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Parent zone '$_parentDomain' contains CNAME '$_subdomainName'."
            else 
                die "Subdomain creation failed."
            fi 
        }
        function create_zone {
            # About: Creates a new domain zone.
            # Arg 1: Domain name.
            # Example: "create_zone example.com" creates example.com
            
            declare -r _domain="${1}"
            declare _success
            
            _success=$(curl --silent -X POST "https://api.cloudflare.com/client/v4/zones" \
                -H "X-Auth-Email: $authEmail" \
                -H "X-Auth-Key: $authKey" \
                -H "Content-Type: application/json" \
                --data "{\"name\":\"$_domain\",\"account\":{\"id\":\"$accountID\"},\"jump_start\":true,\"type\":\"full\"}" \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone
            if [ "$_success" == true ]; then
                msg "Zone '$_domain' created."
            else 
                die "Zone '$_domain' creation failed."
            fi 
        }
        function set_zone {
            # About: Configures a zone with best practices, like always use HTTPS.
            # Arg 1: Domain name
            # Arg 2: Parent domain name. 
            # Example: "set_zone example.com" creates example.com.
            
            declare -r _domain="${1}"
            declare -r _parentDomain="${2:-$parentDomain}" # Use domain defined in config as default if not provided as argument.
            declare -r _zoneID=$(get_zoneId "$_domain")
            declare _success

            #Note: Below automatic Wordpress platform optimization requires cloudfare paid subscription and cloudfare plugin
            # curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/automatic_platform_optimization" \
            #     -H "X-Auth-Email: $authEmail" \
            #     -H "X-Auth-Key: $authKey" \
            #     -H "Content-Type: application/json" \
            #     --data "{\"value\":{\"enabled\":true,\"cf\":true,\"wordpress\":true,\"wp_plugin\":false,\"hostnames\":[\"www.$1\",\"$1],\"cache_by_device_type\":false}}"
            # Use full SSL

            _success=$(curl --silent -X PATCH "https://api.cloudflare.com/client/v4/zones/$_zoneID/settings/ssl" \
                -H "X-Auth-Email: $authEmail" \
                -H "X-Auth-Key: $authKey" \
                -H "Content-Type: application/json" \
                --data '{"value":"full"}' \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Success. Set full SSL."
            else 
                msg "Error. Did not set full SSL."
            fi 

            # Always use HTTPS
            _success=$(curl --silent -X PATCH "https://api.cloudflare.com/client/v4/zones/$_zoneID/settings/always_use_https"\
                -H "X-Auth-Email: $authEmail"\
                -H "X-Auth-Key: $authKey"\
                -H "Content-Type: application/json"\
                --data '{"value":"on"}' \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Success. Set always HTTPS."
            else 
                msg "Error. Did not set always HTTPS."
            fi 

            # Enable Brotli compression
            _success=$(curl --silent -X PATCH "https://api.cloudflare.com/client/v4/zones/$_zoneID/settings/brotli" \
                -H "X-Auth-Email: $authEmail"\
                -H "X-Auth-Key: $authKey"\
                -H "Content-Type: application/json"\
                --data '{"value":"on"}' \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Success. Set Brotli compression."
            else 
                msg "Error. Did not set Brotli compression."
            fi 

            # Point domain to parent domain via CNAME flattening, if specified.
            if [ -n "$_parentDomain" ]; then
                _success=$(curl --silent -X POST "https://api.cloudflare.com/client/v4/zones/$_zoneID/dns_records"\
                    -H "X-Auth-Email: $authEmail"\
                    -H "X-Auth-Key: $authKey"\
                    -H "Content-Type: application/json"\
                    --data "{\"type\":\"CNAME\",\"name\":\"@\",\"content\":\"$_parentDomain\",\"ttl\":120,\"proxied\":true}" \
                    | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

                if [ "$_success" == true ]; then
                    msg "Success. Zone '$_domain' contains CNAME pointing to '$_parentDomain'."
                else 
                    msg "Error. Could not create CNAME on '$_domain' pointing to '$_parentDomain'."
                fi 
            fi
        }

        #~~~~ A La Carte functions ~~~~#
        function on_devmode {
            # About: Disables the Cloudflare cache. Automatically turns off after 3 hours.
            # Arg 1: Domain name
            # Example: `on_devmode "example.com"`
            declare -r _domain="${1}"
            declare -r _zoneID=$(get_zoneId "$_domain")
            declare _success

            _success=$(curl --silent -X PATCH "https://api.cloudflare.com/client/v4/zones/$_zoneID/settings/development_mode" \
                -H "X-Auth-Email: $authEmail" \
                -H "X-Auth-Key: $authKey" \
                -H "Content-Type: application/json" \
                --data '{"value":"on"}' \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Dev Mode is ON for '$_domain'."
            else 
                die "Could not turn Dev Mode on."
            fi 
        }
        function off_devmode {
            # About: Turns dev mode off manually.
            # Arg 1: Domain name
            # Example: `off_devmode "example.com"`
            declare -r _domain="${1}"
            declare -r _zoneID=$(get_zoneId "$_domain")
            declare _success

            _success=$(curl --silent -X PATCH "https://api.cloudflare.com/client/v4/zones/$_zoneID/settings/development_mode" \
            -H "X-Auth-Email: $authEmail" \
            -H "X-Auth-Key: $authKey" \
            -H "Content-Type: application/json" \
            --data '{"value":"off"}' \
            | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Dev Mode is OFF for '$_domain'."
            else 
                die "Could not turn Dev Mode off."
            fi 
        }
        ## delete_zone deletes the specified zone. Example: "delete_zone example.com"
        function delete_zone {
            # About: Deletes an entire zone from a Cloudflare account.
            # Arg 1: Domain name
            declare -r _domain="${1}"
            declare -r _zoneID=$(get_zoneId "$_domain")
            declare _success

            _success=$(curl --silent -X DELETE "https://api.cloudflare.com/client/v4/zones/$_zoneID"\
                -H "X-Auth-Email: $authEmail"\
                -H "X-Auth-Key: $authKey"\
                -H "Content-Type: application/json" \
                | grep --perl-regexp --only-matching '(?<="success":)[^,]*') # pipe data to grep to find the id of the zone

            if [ "$_success" == true ]; then
                msg "Zone '$_domain' deleted."
            else 
                die "Zone '$_domain' not deleted."
            fi 
        }
        "$_command" "$@" # run whatever function is called when script is invoked
        #~~~ END SCRIPT ~~~#
    }
    printf '\n\n%s\n\n' "---$(date)---" >>"$LOG"
    body "$@" |& tee -a "$LOG" # pass arguments to functions and stream console to log; NOTE: do not use 'tee' with 'select' menus!
}
start "$@" # pass arguments called during script source to body