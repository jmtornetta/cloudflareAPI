# About
Simplifies Cloudflare's API into callable functions for common commands like creating domain zones, setting DNS and editing zone properties.
# Instructions
1. Add credentials from Cloudflare's API to "api.config" using favorite text editor and save.
2. Run the following to set up a domain. 
    $ source cfapi.sh;onboardDomain example.com
3. Call other functions from this file as needed using the same format.
    $ source cfapi.sh;deleteDomain example.com
# Misc
Parent Domain works by creating a CNAME subdomain record on parent domain and then mapping the subdomain to the parent domain via CNAME flattening.
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