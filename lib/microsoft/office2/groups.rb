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
end