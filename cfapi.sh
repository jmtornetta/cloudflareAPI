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

        #~~~ Main fetch function ~~~~#
        function fetch_cloudflare {
            # About: Fetches data from Cloudflare API. Used to compose other functions. Handles pagination.
            declare -r _endpoint="${1}"
            declare -r _httpMethod="${2:-GET}"
            declare -r _data="${3:-}"

            declare -r _url="https://api.cloudflare.com/client/v4/$_endpoint"
            declare -r _dataParam="${_data:+-d "$_data"}"
            declare _response
            declare _totalPages
            declare _result

            _response=$(curl --silent -X $_httpMethod "$_url" \
                -H "X-Auth-Email: $authEmail" \
                -H "X-Auth-Key: $authKey" \
                -H "Content-Type: application/json" \
                $_dataParam)
            [ -z "$_response" ] && die "No response received."
            declare _success=$(echo "$_response" | jq -r '.success')
            [ "$_success" == true ] || die "Response not successful. Response:" "$_response"

            _totalPages=$(echo "$_response" | jq -r '.result_info.total_pages')
            _result=$(echo "$_response" | jq -r '.result[]')
            
            if [ $_totalPages -gt 1 ]; then
                msg "$_totalPages pages of results. Fetching remaining..."
                for i in $(seq 2 $_totalPages); do
                    # if endpoint contains a query string, append page number to it
                    declare _newUrl=$(echo "$_url" | grep -q '?' && echo "$_url&page=$i" || echo "$_url?page=$i")
                    _response=$(curl --silent -X $_httpMethod "$_newUrl" \
                        -H "X-Auth-Email: $authEmail" \
                        -H "X-Auth-Key: $authKey" \
                        -H "Content-Type: application/json")
                    _result+="$(echo "$_response" | jq -r '.result[]')"
                done
            fi
            msg "Results:" "$_result"
            echo "$_result" # returns the response to standard output for other functions & scripts
        }

        #~~~ Guard clauses ~~~~#
        [ -z "$_command" ] && die "Must provide function to call as first argument of script."

        #~~~ Modules ~~~~#
        function check_record {
            # About: Loop through each domain and check if a CNAME record exists with the required value ("kinstavalidation.app"). If not, create it.
            declare -r _domainOrZoneId="${1}"
            declare -r _recordName="${2}"
            declare -r _recordValue="${3}"
            declare _recordType="${4:-}"

            declare _zoneID
            if [[ "$_domainOrZoneId" =~ \. ]]; then
                _zoneID=$(get_zoneId "$_domainOrZoneId")
            else
                _zoneID="$_domainOrZoneId"
            fi

            declare _cnameCurrentValue
            declare _dnsRecords

            _dnsRecords=$(fetch_cloudflare "zones/$_zoneID/dns_records")
            # find "zone_name" in response to get domain name for output; only keep the first value found
            _domainFromFirstRecord=$(echo "$_dnsRecords" | jq -r '.zone_name' | head -n 1)
            _recordCurrentValue=$(echo "$_dnsRecords" | jq -r --arg recordName "$_recordName" 'select(.name | startswith($recordName)) | .content')
            [ -z "$_domainFromFirstRecord" ] && die "No records found for zone ID '$_zoneID'."

            echo
            msg '%s\n' "Domain: '$_domainFromFirstRecord" "Name: '$_recordName'" "Value: '$_recordCurrentValue'"
            echo
            if [ -n "$_recordCurrentValue" ]; then
                msg '%s\n' "Record exists." "Current value: $_recordCurrentValue" "Expected value: $_recordValue"
                # if current value is not the required value, ask user if they want to update it
                if [ "$_recordCurrentValue" == "$_recordValue" ]; then
                    msg "Record is correct. No action needed."
                else
                    msg '\n%s\t' "Delete all similar records and create new [y/N]?" && read -r _deleteRecord
                    if [ "$_deleteRecord" == "y" ]; then
                        if [ -z "$_recordType" ]; then
                            msg '\n%s\t' "Enter new record type [A/CNAME/TXT...]:" && read -r _recordType
                        fi
                        _recordIDs=$(echo "$_dnsRecords" | jq -r --arg recordName "$_recordName" 'select(.name | startswith($recordName)) | .id')
                        for _recordID in $_recordIDs; do
                            _dnsRecords=$(fetch_cloudflare "zones/$_zoneID/dns_records/$_recordID" "DELETE") && msg "Record deleted. ID: $_recordID"
                        done
                        create_zone_record "$_zoneID" "$_recordType" "$_recordName" "$_recordValue" "false"
                    else
                        msg "Record not deleted."
                    fi
                fi
            else
                msg '\n%s\t' "Record does not exist. Create it [y/N]?" && read -r _createRecord
                if [ "$_createRecord" == "y" ]; then
                    if [ -z "$_recordType" ]; then
                        msg '\n%s\t' "Enter record type [A/CNAME/TXT...]:" && read -r _recordType
                    fi
                    create_zone_record "$_zoneID" "$_recordType" "$_recordName" "$_recordValue" "false"
                else
                    msg "Record not created."
                fi
            fi
        }
        function check_all_acme_cnames {
            # About: Loop through each domain and check if a CNAME record exists with the required value ("kinstavalidation.app"). If not, create it.
            declare -r _cnameName="_acme-challenge"
            declare -r _cnameValue="kinstavalidation.app"

            declare _result
            declare _domainEntry
            declare _zoneID

            _result=$(get_all_zones)
            # loop over each domain but don't skip user input read lines
            for _domainEntry in $_result; do
                IFS='|' read -r _domain _zoneID <<<"$_domainEntry"
                check_record "$_zoneID" "$_cnameName" "$_domain.$_cnameValue" "CNAME"
            done
        }
        function get_zoneId {
            # About: Finds the domain ID for a domain name.
            declare -r _domain="${1}"
            declare _zoneId
            set +e # So error message can be returned if _zoneId returns null
            _zoneId=$(fetch_cloudflare "zones?name=$_domain&account.id=$accountID" | jq -r '.[0].id')
            [ -z "$_zoneId" ] && die "Could not find zone ID for '$_domain' in account."
            set -e
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
        function set_zone {
            # About: Configures a zone with best practices, like always use HTTPS.
            # Arg 1: Domain name
            # Arg 2: Parent domain name. 
            # Example: "set_zone example.com" creates example.com.
            
            declare -r _domain="${1}"
            declare -r _parentDomain="${2:-$parentDomain}" # Use domain defined in config as default if not provided as argument.
            declare -r _zoneID=$(get_zoneId "$_domain")
            
            declare _result
            
            # Use full SSL
            _result=$(fetch_cloudflare "zones/$_zoneID/settings/ssl" "PATCH" '{"value":"full"}')
            [ -n "$_result" ] && msg "Success. Set full SSL." || die "Error. Did not set full SSL."

            # Always use HTTPS
            _result=$(fetch_cloudflare "zones/$_zoneID/settings/always_use_https" "PATCH" '{"value":"on"}')
            [ -n "$_result" ] && msg "Success. Set always HTTPS." || die "Error. Did not set always HTTPS."

            # Enable Brotli compression
            _result=$(fetch_cloudflare "zones/$_zoneID/settings/brotli" "PATCH" '{"value":"on"}')
            [ -n "$_result" ] && msg "Success. Set Brotli compression." || die "Error. Did not set Brotli compression."

            # Point domain to parent domain via CNAME flattening, if specified.
            [ -n "$_parentDomain" ] && create_zone_record "$_zoneID" "CNAME" "@" "$_parentDomain" "true"
            
            #Note: Below automatic Wordpress platform optimization requires cloudfare paid subscription and cloudfare plugin
            # curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$zoneID/settings/automatic_platform_optimization" \
            #     -H "X-Auth-Email: $authEmail" \
            #     -H "X-Auth-Key: $authKey" \
            #     -H "Content-Type: application/json" \
            #     --data "{\"value\":{\"enabled\":true,\"cf\":true,\"wordpress\":true,\"wp_plugin\":false,\"hostnames\":[\"www.$1\",\"$1],\"cache_by_device_type\":false}}"
            
        }
        #~~~~ Functions~~~~$
        function get_all_zones {
            # About: Fetches all zones in a Cloudflare account.
            declare _response
            declare _zones

            _response=$(fetch_cloudflare "zones?account.id=$accountID")
            _zones=$(echo "$_response" | jq -r '"\(.name)|\(.id)"')

            echo "$_zones" # returns the zone names and IDs to standard output for other functions & scripts
        }
        function create_subdomain {
            # About: Create a CNAME for subdomain on a parent domain.
            # Arg 1: Sub-domain (example.com).
            # [Arg 2]: Parent domain. Defaults to config file.

            declare -r _subdomainName="${1//./}" # Removes '.' from domain name.
            declare -r _parentDomain="${2:-$parentDomain}" # Use domain defined in config as default if not provided as argument.
            declare -r _zoneID=$(get_zoneId "$_parentDomain") # Runs above function and assigns parent zone ID to new internal variable.
            
            declare _result

            _result=$(fetch_cloudflare "zones/$_zoneID/dns_records" "POST" "{\"type\":\"CNAME\",\"name\":\"$_subdomainName\",\"content\":\"$_parentDomain\",\"ttl\":120,\"proxied\":true}")
            [ -n "$_result" ] && msg "Subdomain created. Name: $_subdomainName, Value: $_parentDomain" || die "Subdomain creation failed."
        }
        function create_zone {
            # About: Creates a new domain zone.
            declare -r _domain="${1}"
            declare _result
            
            _result=$(fetch_cloudflare "zones" "POST" "{\"name\":\"$_domain\",\"account\":{\"id\":\"$accountID\"},\"jump_start\":true,\"type\":\"full\"}")
            [ -n "$_result" ] && msg "Zone '$_domain' created." || die "Zone '$_domain' creation failed."
        }
        function create_zone_record {
            # About: Creates a new DNS record in a zone.
            declare -r zoneID="${1}"
            declare -r recordType="${2}"
            declare -r recordName="${3}"
            declare -r recordValue="${4}"
            declare -r proxied="${5}" # true or false

            declare _result
            _result=$(fetch_cloudflare "zones/$zoneID/dns_records" "POST" "{\"type\":\"$recordType\",\"name\":\"$recordName\",\"content\":\"$recordValue\",\"proxied\":$proxied}")
            [ -n "$_result" ] && msg "Record created. Name: $recordName, Value: $recordValue" || die "Record creation failed."
        }

        #~~~~ A La Carte functions ~~~~#
        function on_devmode {
            # About: Disables the Cloudflare cache. Automatically turns off after 3 hours.
            # Arg 1: Domain name
            # Example: `on_devmode "example.com"`
            declare -r _domain="${1}"
            declare -r _zoneID=$(get_zoneId "$_domain")
            
            declare _result

            _result=$(fetch_cloudflare "zones/$_zoneID/settings/development_mode" "PATCH" '{"value":"on"}')
            [ -n "$_result" ] && msg "Dev Mode is ON for '$_domain'." || die "Could not turn Dev Mode on."
        }
        function off_devmode {
            # About: Turns dev mode off manually. Automatically turns off after 3 hours.
            declare -r _domain="${1}"
            declare -r _zoneID=$(get_zoneId "$_domain")
            
            declare _result

            _result=$(fetch_cloudflare "zones/$_zoneID/settings/development_mode" "PATCH" '{"value":"off"}')
            [ -n "$_result" ] && msg "Dev Mode is OFF for '$_domain'." || die "Could not turn Dev Mode off."
        }
        ## delete_zone deletes the specified zone. Example: "delete_zone example.com"
        function delete_zone {
            # About: Deletes an entire zone from a Cloudflare account.
            # Arg 1: Domain name
            declare -r _domain="${1}"
            declare -r _zoneID=$(get_zoneId "$_domain")

            declare _result
            _result=$(fetch_cloudflare "zones/$_zoneID" "DELETE")
            [ -n "$_result" ] && msg "Zone '$_domain' deleted." || die "Zone '$_domain' not deleted."
        }
        "$_command" "$@" # run whatever function is called when script is invoked
        #~~~ END SCRIPT ~~~#
    }
    printf '\n\n%s\n\n' "---$(date)---" >>"$LOG"
    body "$@" |& tee -a "$LOG" # pass arguments to functions and stream console to log; NOTE: do not use 'tee' with 'select' menus!
}
start "$@"
