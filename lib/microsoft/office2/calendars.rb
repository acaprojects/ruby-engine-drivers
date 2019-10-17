module Microsoft::Office2::Calendars
    ##
    # CRUD for MS Graph API Calendars
    # https://docs.microsoft.com/en-us/graph/api/resources/calendar?view=graph-rest-1.0
    # 
    # @param mailbox [String] The mailbox where the calendars will be created/read
    # @param limit [String] The maximum number of calendars to return
    def list_calendars(mailbox:, calendargroup_id:nil, match:nil, search:nil, limit:nil)
        query_params = { '$top': (limit || 99) }
        case calendargroup_id
        when nil
            endpoint = "/v1.0/users/#{mailbox}/calendars"
        when 'default'
            endpoint = "/v1.0/users/#{mailbox}/calendarGroup/calendars"
        else
            endpoint = "/v1.0/users/#{mailbox}/calendarGroups/#{calendargroup_id}/calendars"
        end

        if match
            query_params['$filter'] = "name eq '#{match}'"
        elsif search
            query_params['$filter'] = "startswith(name,'#{search}')"
        end

        request = graph_request(request_method: 'get', endpoints: [endpoint], query: query_params)
        check_response(request)
        JSON.parse(request.body)['value']
    end

    def list_calendargroups(mailbox:, limit:nil)
        query_params = { '$top': (limit || 99) }
        endpoint = "/v1.0/users/#{mailbox}/calendarGroups"
        request = graph_request(request_method: 'get', endpoints: [endpoint], query: query_params)
        check_response(request)
        JSON.parse(request.body)['value']
    end
    
    # Add a new calendar to the passed in mailbox.
    # @param name [String] The name for any new calendar/group being created
    # @param calendargroup_id [String] Optional: The ID of the calendargroup inside which to create the calendar
    def create_calendar(mailbox:, name:, calendargroup_id: nil)
        case calendargroup_id
        when nil
            endpoint = "/v1.0/users/#{mailbox}/calendars"
        when 'default'
            endpoint = "/v1.0/users/#{mailbox}/calendarGroup/calendars"
        else
            endpoint = "/v1.0/users/#{mailbox}/calendarGroups/#{calendargroup_id}/calendars"
        end
        request = graph_request(request_method: 'post', endpoints: [endpoint], data: {name: name})
        check_response(request)
        JSON.parse(request.body)
    end

    def create_calendargroup(mailbox:, name:)
        endpoint = "/v1.0/users/#{mailbox}/calendarGroups"
        request = graph_request(request_method: 'post', endpoints: [endpoint], data: {name: name})
        check_response(request)
        JSON.parse(request.body)
    end

    
    # Delete a calendar from the passed in mailbox.
    # @param id [String] The ID of the calendar to be deleted
    # @param calendargroup_id [String] Optional: The ID of the calendargroup in which to locate the calendar
    def delete_calendar(mailbox:, id:, calendargroup_id: nil)
        case calendargroup_id
        when nil
            endpoint = "/v1.0/users/#{mailbox}/calendars/#{id}"
        when 'default'
            endpoint = "/v1.0/users/#{mailbox}/calendarGroup/calendars/#{id}"
        else
            endpoint = "/v1.0/users/#{mailbox}/calendarGroups/#{calendargroup_id}/calendars/#{id}"
        end
        request = graph_request(request_method: 'delete', endpoints: [endpoint])
        check_response(request)
    end

    def delete_calendargroup(mailbox:, id:)
        endpoint = "/v1.0/users/#{mailbox}/calendarGroups/#{id}"
        request = graph_request(request_method: 'delete', endpoints: [endpoint])
        check_response(request)
    end
end