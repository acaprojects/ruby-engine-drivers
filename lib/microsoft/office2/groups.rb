module Microsoft::Office2::Groups
    # List all groups that the given user is a direct and INDIRECT member of (i.e. list all the user's groups and subgroups)
    # id: email or other ID of the target User
    # result_fields: comma seperated string of which group properties should be included in the result. e.g. 'id,displayName'. Defaults to just 'displayName'
    # transitive: if false then only list groups that the user is a DIRECT member of (i.e. don't list subgroups)
    # https://docs.microsoft.com/en-us/graph/api/user-list-memberof
    def list_user_member_of(id, result_fields = 'id,displayName', transitive = true)
        return {'error': "400: No group \'id\' supplied" } if id.nil?
        endpoint = "/v1.0/users/#{id}/" + (transitive ? 'transitiveMemberOf' : 'memberOf')
        response = graph_request(request_method: 'get', endpoints: [endpoint], query: { '$select': result_fields, '$top': 999 } )
        check_response(response)
        JSON.parse(response.body)['value']
    end
    
    
    # Return all the groups that the user is a member of. The check is transitive, unlike reading the memberOf navigation property, 
    # which returns only the groups that the user is a direct member of.
    # This function supports Office 365 and other types of groups provisioned in Azure AD. 
    # The maximum number of groups each request can return is 2046. Note that Office 365 Groups cannot contain groups. 
    # So membership in an Office 365 Group is always direct.
    # id: user id or userPrincipalName
    # result_fields: array of strings of group names to which user belongs 
    # https://docs.microsoft.com/en-us/graph/api/user-getmembergroups
    def get_member_groups(id, result_fields = '', transitive = true)
        return {'error': "400: No user \'id\' supplied" } if id.nil?
        endpoint = "/v1.0/users/#{id}/getMemberGroups"
        response = graph_request(request_method: 'get', endpoints: [endpoint], query: {  '$top': 999 } )
        check_response(response)
        JSON.parse(response.body)['value']
    end


end
