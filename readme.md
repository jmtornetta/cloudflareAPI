# About
A library of Linux-native functions which use Cloudflare's API to speed up DNS onboarding and management. Create zones, set DNS records, and edit properties from your terminal or program.  
# Instructions
1. Copy "api.default.config" to "api.config"  
2. Add credentials from Cloudflare's API to "api.config" and save. Acquire from "https://dash.cloudflare.com/profile/api-tokens".
3. Call the script with a function as the first argument. Examples:  
```./cfapi.sh onboard_zone "example.com"```   
```./cfapi.sh delete_zone "example.com"```  
## Config > Parent Domain
Specify a Cloudflare domain name here ("parent-example.com") to have any new domain ("child-example.com") utilize the same endpoint as the parent.
1. A CNAME record pointing to the parent will be created on the new domain. This uses CNAME flattening via Cloudlfare so an 'A record' is never needed.  
2. A concatenated CNAME record will be created on the parent domain to represent the child domain ("child-examplecom"). This can be deleted if not needed.  
Leave blank if not using a parent domain.
<table>
    <tr>
        <th>Type</th>
        <th>Name</th>
        <th>Content</th>
    </tr>
    <tr>
        <td>CNAME</td>
        <td>subdomain</td>
        <td>parentdomain.com</td>
    </tr>
</table>
