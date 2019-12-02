module Microsoft::Office2::Events
    ##
    # For every mailbox (email) passed in, this method will grab all the bookings and, if
    # requested, return the availability of the mailboxes for some time range.
    # https://docs.microsoft.com/en-us/graph/api/user-list-events?view=graph-rest-1.0&tabs=http
    #
    # @param mailboxes [Array] An array of mailbox emails to pull bookings from. These are generally rooms but could be users.
    # @option options [Integer] :created_from Get all the bookings created after this seconds epoch
    # @option options [Integer] :start_param Get all the bookings that occurr between this seconds epoch and end_param
    # @option options [Integer] :end_param Get all the bookings that occurr between this seconds epoch and start_param
    # @option options [Integer] :available_from If bookings exist between this seconds epoch and available_to then the room is market as not available
    # @option options [Integer] :available_to If bookings exist between this seconds epoch and available_from then the room is market as not available
    # @option options [Array] :ignore_bookings An array of icaluids for bookings which are ignored if they fall within the available_from and to time range
    # @option options [String] :extension_name The name of the extension list to retreive in O365. This probably doesn't need to change
    # @return [Hash] A hash of room emails to availability and bookings fields, eg:
    # @example
    # An example response:
    #   {
    #     'room1@example.com' => {
    #       available: false,
    #       bookings: [
    #         {
    #           subject: 'Blah',
    #           start_epoch: 1552974994
    #           ...
    #         }, {
    #           subject: 'Foo',
    #           start_epoch: 1552816751
    #           ...
    #         }
    #       ]   
    #     },
    #     'room2@example.com' => {
    #       available: false,
    #       bookings: [{
    #         subject: 'Blah',
    #         start_epoch: 1552974994
    #       }]
    #       ...
    #     }
    #   }
    def get_bookings(mailboxes:, calendargroup_id: nil, calendar_id: nil, options:{})
        default_options = {
            created_from: nil,  
            bookings_from: nil,
            bookings_to: nil,
            available_from: nil,
            available_to: nil,
            ignore_bookings: [],
            extension_name: "Com.Acaprojects.Extensions"
        }
        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        # We should always have an array of mailboxes
        mailboxes = Array(mailboxes)

        # We need at least one of these params
        if options[:bookings_from].nil? && options[:available_from].nil? && options[:created_from].nil?
            raise "either bookings_from, available_from or created_from is required"
        end

        # If there is no params to get bookings for, set those based on availability params and vice versa
        if options[:available_from].present? && options[:bookings_from].nil? 
             options[:bookings_from] = options[:available_from]
             options[:bookings_to] = options[:available_to]
        elsif options[:bookings_from].present? && options[:available_from].nil? 
             options[:available_from] = options[:bookings_from]
             options[:available_to] = options[:bookings_to]
        end

        calendar_endpoint = calendar_path(calendargroup_id, calendar_id) + (options[:created_from] ? "/events" : "/calendarView")   # If we are using created_from then we cannot use the calendarView and must use events
        all_endpoints = mailboxes.map { |email| "/users/#{email}#{calendar_endpoint}" }

        # This is currently the max amount of queries per bulk request
        slice_size = 20
        responses = []
        all_endpoints.each_slice(slice_size).with_index do |endpoints, ind|
            query = {
                '$top': 10000
            }
            # Add the relevant query params
            query[:startDateTime] = graph_date(options[:bookings_from]) if options[:bookings_from]
            query[:endDateTime] = graph_date(options[:bookings_to]) if options[:bookings_to]
            query[:'$filter'] = "createdDateTime gt #{created_from}" if options[:created_from]
            query[:'$expand'] = "extensions($filter=id eq '#{options[:extension_name]}')" if options[:extension_name]

            # Make the request, check the repsonse then parse it
            bulk_response = graph_request(request_method: 'get', endpoints: endpoints, query: query, bulk: true)
            check_response(bulk_response)
            parsed_response = JSON.parse(bulk_response.body)['responses']

            # Ensure that we reaggregate the bulk requests correctly
            parsed_response.each do |res|
                local_id = res['id'].to_i
                global_id = local_id + (slice_size * ind.to_i)
                res['id'] = global_id
                responses.push(res)
            end
        end

        # Arrange our bookings by room
        bookings_by_room = {}
        responses.each_with_index do |res, i|
            bookings = res['body']['value']
            is_available = true
            next unless bookings
            # Go through each booking and extract more info from it
            bookings.each_with_index do |booking, i|
                bookings[i] = Microsoft::Office2::Event.new(client: self, event: booking, available_to: options[:available_to], available_from: options[:available_from]).event
                is_available = false if !bookings[i]['is_free'] && !options[:ignore_bookings].include?(bookings[i]['icaluid'])
            end
            bookings_by_room[mailboxes[res['id'].to_i]] = {available: is_available, bookings: bookings}
        end
        bookings_by_room
    end
    
    # Return a booking with a matching icaluid
    def get_booking_by_icaluid(icaluid:, mailbox:, calendargroup_id: nil, calendar_id: nil)
        query_params =  {'$filter': "iCalUId eq '#{icaluid}'" }
        endpoint = "/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events"
        response = graph_request(request_method: 'get', endpoints: [endpoint], query: query_params)
        check_response(response)
        JSON.parse(response.body)&.dig('value', 0)
    end
    
    ##
    # Create an Office365 event in the mailbox passed in. This may have rooms and other 
    # attendees associated with it and thus create events in other mailboxes also.
    # https://docs.microsoft.com/en-us/graph/api/user-post-events?view=graph-rest-1.0&tabs=http
    #
    # @param mailbox [String] The mailbox email in which the event is to be created. This could be a user or a room though is generally a user
    # @param start_param [Integer] A seconds epoch which denotes the start of the booking
    # @param end_param [Integer] A seconds epoch which denotes the end of the booking
    # @option options [Array] :rooms An array of room resource emails to be added to the booking. They will get added to attendees[] with "type: resource"
    # @option options [String] :subject A subject for the booking
    # @option options [String] :description A description to be added to the body of the event
    # @option options [String] :organizer_name The name of the organizer
    # @option options [String] :organizer_email The email of the organizer
    # @option options [Array] :attendees An array of attendees to add in the form { name: <NAME>, email: <EMAIL> }
    # @option options [String] :recurrence_type The type of recurrence if used. Can be 'daily', 'weekly' or 'monthly'
    # @option options [Integer] :recurrence_end A seconds epoch denoting the final day of recurrence
    # @option options [Boolean] :is_private Whether to mark the booking as private or just normal
    # @option options [String] :timezone The timezone of the booking. This will be overridden by a timezone in the room's settings
    # @option options [Hash] :extensions A hash holding a list of extensions to be added to the booking
    # @option options [String] :location The location field to set. This will not be used if a room is passed in
    def create_booking(mailbox:, start_param:, end_param:, calendargroup_id: nil, calendar_id: nil, options: {})
        default_options = {
            rooms: [],
            subject: "Meeting",
            description: nil,
            organizer: { name: nil, email: mailbox },
            attendees: [],
            recurrence: nil,
            is_private: false,
            timezone: 'UTC',
            extensions: {},
            location: nil
        }
        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        # Create the JSON body for our event
        event_json = create_event_json(
            subject: options[:subject],
            body: options[:description],
            rooms: options[:rooms],
            start_param: start_param,
            end_param: end_param,
            timezone: options[:timezone],
            location: options[:location],
            attendees: options[:attendees].dup,
            organizer: options[:organizer],
            recurrence: options[:recurrence],
            extensions: options[:extensions],
            is_private: options[:is_private]
        )
        
        # Make the request and check the response
        begin
            retries ||= 0
            request = graph_request(request_method: 'post', endpoints: ["/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events"], data: event_json)
            check_response(request)
        rescue Microsoft::Error::Conflict => e
	    if (retries += 1) < 3
	        sleep(rand())
                retry
	    end
        end
        Microsoft::Office2::Event.new(client: self, event: JSON.parse(request.body)).event
    end

    ##
    # Update an Office365 event with the relevant booking ID and in the mailbox passed in.
    # 
    # @param booking_id [String] The ID of the booking which is to be updated
    # @param mailbox [String] The mailbox email in which the event is to be created. This could be a user or a room though is generally a user
    # @option options [Integer] :start_param A seconds epoch which denotes the start of the booking
    # @option options [Integer] :end_param A seconds epoch which denotes the end of the booking
    # @option options [Array] :rooms An array of room resource emails to be added to the booking. They will get added to attendees[] with "type: resource"    
    # @option options [String] :subject A subject for the booking
    # @option options [String] :description A description to be added to the body of the event
    # @option options [String] :organizer_name The name of the organizer
    # @option options [String] :organizer_email The email of the organizer
    # @option options [Array] :attendees An array of attendees to add in the form { name: <NAME>, email: <EMAIL> }
    # @option options [String] :recurrence_type The type of recurrence if used. Can be 'daily', 'weekly' or 'monthly'
    # @option options [Integer] :recurrence_end A seconds epoch denoting the final day of recurrence
    # @option options [Boolean] :is_private Whether to mark the booking as private or just normal
    # @option options [String] :timezone The timezone of the booking. This will be overridden by a timezone in the room's settings
    # @option options [Hash] :extensions A hash holding a list of extensions to be added to the booking
    # @option options [String] :location The location field to set. This will not be used if a room is passed in
    def update_booking(booking_id:, mailbox:, calendargroup_id: nil, calendar_id: nil, options: {})
        default_options = {
            start_param: nil,
            end_param: nil,
            rooms: [],
            subject: "Meeting",
            description: nil,
            attendees: [],
            recurrence: nil,
            is_private: false,
            timezone: 'UTC',
            extensions: {},
            location: nil
        }
        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        # Create the JSON body for our event
        event_json = create_event_json(
            subject: options[:subject],
            body: options[:description],
            rooms: options[:rooms],
            start_param: options[:start_param],
            end_param: options[:end_param],
            timezone: options[:timezone],
            location: options[:location],
            attendees: options[:attendees].dup,
            recurrence: options[:recurrence],
            extensions: options[:extensions],
            is_private: options[:is_private]
        )

        # If extensions exist we must make a separate request to add them
        if options[:extensions].present?
            options[:extensions] = options[:extensions].dup
            options[:extensions]["@odata.type"] = "microsoft.graph.openTypeExtension"
            options[:extensions]["extensionName"] = "Com.Acaprojects.Extensions"
            request = graph_request(request_method: 'put', endpoints: ["/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events/#{booking_id}/extensions/Microsoft.OutlookServices.OpenTypeExtension.Com.Acaprojects.Extensions"], data: options[:extensions])
            check_response(request)
            ext_data = JSON.parse(request.body)
        end

        # Make the request and check the response
        begin
            request = graph_request(request_method: 'patch', endpoints: ["/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events/#{booking_id}"], data: event_json)
            check_response(request)
        rescue Microsoft::Error::Conflict => e
            if (retries += 1) < 3
                sleep(rand()*2)
                retry
            end
        end 
        Microsoft::Office2::Event.new(client: self, event: JSON.parse(request.body).merge({'extensions' => [ext_data]})).event
    end

    ##
    # Delete a booking from the passed in mailbox.
    # 
    # @param mailbox [String] The mailbox email which contains the booking to delete
    # @param booking_id [String] The ID of the booking to be deleted
    def delete_booking(mailbox:, booking_id:, calendargroup_id: nil, calendar_id: nil)
        endpoint = "/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events/#{booking_id}"
        begin
            request = graph_request(request_method: 'delete', endpoints: [endpoint])
            check_response(request)
        rescue Microsoft::Error::Conflict => e
            if (retries += 1) < 3
                sleep(rand()*2)
                retry
            end
        end
        200
    end
    
    ##
    # Decline a meeting
    # 
    # @param mailbox [String] The mailbox email which contains the booking to delete
    # @param booking_id [String] The ID of the booking to be deleted
    # @param comment [String] An optional message that will be included in the body of the automated email that will be sent to the host of the meeting
    def decline_meeting(mailbox:, booking_id:, comment: '', calendargroup_id: nil, calendar_id: nil)
        endpoint = "/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events/#{booking_id}/decline"
        request = graph_request(request_method: 'post', endpoints: [endpoint], data: {comment: comment})
        check_response(request)
        200
    end
    
    protected

    def calendar_path(calendargroup_id, calendar_id)
        result  = ""
        result += "/calendarGroups/#{calendargroup_id}" if calendargroup_id
        result += "/calendars/#{calendar_id}"           if calendar_id
        result
    end

    def create_event_json(subject: nil, body: nil, start_param: nil, end_param: nil, timezone: nil, rooms: [], location: nil, attendees: nil, organizer_name: nil, organizer:nil, recurrence: nil, extensions: {}, is_private: false)
        # Put the attendees into the MS Graph expeceted format
        attendees.map! do |a|
            attendee_type = ( a[:optional] ? "optional" : "required" )
            { emailAddress: { address: a[:email], name: a[:name] }, type: attendee_type }
        end

        # Add each room to the attendees array
        rooms.each do |room|
            attendees.push({ type: "resource", emailAddress: { address: room[:email], name: room[:name] } })
        end


        event_json = {}
        event_json[:subject] = subject
        event_json[:attendees] = attendees
        event_json[:sensitivity] = ( is_private ? "private" : "normal" )

        event_json[:body] = {
            contentType: "HTML",
            content: (body || "")
        }

        start_date = Time.at(start_param).to_datetime.in_time_zone(timezone)
        event_json[:start] = {
            dateTime: start_date.strftime('%FT%R'),
            timeZone: timezone
        } if start_param

        end_date   = Time.at(end_param).to_datetime.in_time_zone(timezone)
        event_json[:end] = {
            dateTime: end_date.strftime('%FT%R'),
            timeZone: timezone
        } if end_param

        # If we have rooms then use that, otherwise use the location string. Fall back is [].
        event_json[:locations] = rooms.present? ? rooms.map { |r| { displayName: r[:name] } } : location ? [{displayName: location}] : []

        event_json[:organizer] = {
            emailAddress: {
                address: organizer[:email],
                name: organizer[:email] || organizer[:email]
            }
        } if organizer


        ext = {
            "@odata.type": "microsoft.graph.openTypeExtension",
            "extensionName": "Com.Acaprojects.Extensions"
        }
        extensions.each do |ext_key, ext_value|
            ext[ext_key] = ext_value
        end
        event_json[:extensions] = [ext]

        if recurrence
            recurrence_end_date = Time.at(recurrence[:end]).to_datetime.in_time_zone(timezone)
            event_json[:recurrence] = {
                pattern: {
                    type:       recurrence[:type],
                    interval:   1,
                    daysOfWeek: [start_date.strftime("%A")]
                },
                range: {
                    type:      'endDate',
                    startDate: start_date.strftime("%F"),
                    endDate:   recurrence_end_date.strftime("%F")
                }
            }
        end

        event_json.reject!{|k,v| v.nil?} 
        event_json
    end
end
