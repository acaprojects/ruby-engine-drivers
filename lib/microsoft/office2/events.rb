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
            ignore_bookings: []
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
    def get_booking_by_icaluid(icaluid:, mailbox:, calendargroup_id: nil, calendar_id: nil, start_epoch: nil)
        if start_epoch
            # if a start epoch is given, search a 48hr window around it using /calendarView
            # /calendarView returns all events, including recurrences
            start = Time.at(start_epoch.to_i)
            endpoint = "/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/calendarView"
            query_params =  {'$filter': "iCalUId eq '#{icaluid}'", 'startDateTime': start.yesterday.strftime('%FT%T%:z'), 'endDateTime': start.tomorrow.strftime('%FT%T%:z')}
        else
            # if a start epoch is not given, use /events
            # /events does not return event recurrences
            endpoint = "/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events"
            query_params =  {'$filter': "iCalUId eq '#{icaluid}'" }
        end
        response = graph_request(request_method: 'get', endpoints: [endpoint], query: query_params)
        check_response(response)
        JSON.parse(response.body)&.dig('value', 0)
    end

    MAX_RECURRENCE = UV::Scheduler.parse_duration(ENV['O365_MAX_BOOKING_WINDOW'] || '180d')
    def unroll_recurrence(start:, interval: nil, recurrence_end: nil)
        occurences = [current_occurence = start]
        return occurences unless interval
	end_date = Time.at(recurrence_end || start + MAX_RECURRENCE).midnight.tomorrow.to_i # whole day intervals for  recurrence end date
        loop do
            next_occurence = current_occurence + interval
            return occurences if next_occurence > end_date
            occurences << next_occurence
            current_occurence = next_occurence
        end 
    end

    RECURRENCE_MAP = { daily: 1.days.to_i, weekly: 1.week.to_i, monthly: 1.month.to_i }
    def get_availability(rooms:, from:, to:, recurrence_pattern: 'none', recurrence_end: nil, ignore_icaluid: nil)
        interval = RECURRENCE_MAP[recurrence_pattern]
        start_epochs = unroll_recurrence(start: from, interval: interval,  recurrence_end: recurrence_end)
        event_length = to - from
        query_strings = start_epochs.map { |start| "?startDateTime=#{graph_date(start)}&endDateTime=#{graph_date(start + event_length)}&$top=99" }

        # create array of requests that will be sent as bulk to Graph API. Match the array index with the request ID, for simple response parsing
        requests = []
        rooms.each do |room_email|
            room_events_endpoint =  "/users/#{room_email}/calendar/calendarView"
            query_strings.each_with_index do |query_string, i|
                requests << { id: "#{room_email}:#{start_epochs[i]}", method: 'GET', url: room_events_endpoint + query_string }
            end
        end

        responses = raw_bulk_request(requests)
        conflicts = {}
        all_conflicts = []
        # search for conflicts
        responses.each do |response|
            events = response&.dig('body', 'value')
            next unless events.any?
            # There is at least one conflict, but if it's the same booking currently being edited, then ignore it
            room,start_epoch = response['id'].split(':')
            events.each do |event|
                unless event['iCalUId'] == ignore_icaluid
                    conflicts[room] ||= []
                    start = event['start']
                    clashing_start_epoch = ActiveSupport::TimeZone.new(start['timeZone']).parse(start['dateTime']).to_i
                    conflicts[room] << clashing_start_epoch
                    all_conflicts << clashing_start_epoch
                end
            end
        end
        return { conflicts: conflicts, first_conflict: all_conflicts.min }
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
            timezone: ENV['TZ'],
            location: nil,
            showAs: 'busy',
            responseRequested: true
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
            is_private: options[:is_private],
            showAs: options[:showAs],
            responseRequested: options[:responseRequested]
        )
        
        # Make the request and check the response
        begin
            # retries ||= 0
            response = graph_request(request_method: 'post', endpoints: ["/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events"], data: event_json)
            check_response(response)
        rescue Microsoft::Error::Conflict => e
            return {}
        end
	    
	begin 
            Microsoft::Office2::Event.new(client: self, event: JSON.parse(response.body)).event
	rescue error
	    return {}
	end
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
    # @option options [String] :location The location field to set. This will not be used if a room is passed in
    def update_booking(booking_id:, mailbox:, calendargroup_id: nil, calendar_id: nil, options: {})
    # No defaults for editing, because undefined fields should simply retain the existing value (from the original booking)
        default_options = {
            start_param: nil,
            end_param: nil,
            rooms: nil,
            subject: nil,
            description: nil,
            attendees: nil,
            recurrence: nil,
            is_private: nil,
            timezone: ENV['TZ'],
            location: nil
        }
        # Merge in our default options with those passed in
        options = options.reverse_merge(default_options)

        # Create the JSON body for our event
        event_json = create_event_json(
            subject: options[:subject],
            body: (options[:body] || options[:description]),
            rooms: options[:rooms],
            start_param: options[:start_param],
            end_param: options[:end_param],
            timezone: options[:timezone],
            location: options[:location],
            attendees: options[:attendees].dup,
            recurrence: options[:recurrence],
            is_private: options[:is_private]
        )

        # Make the request and check the response
        begin
            request = graph_request(request_method: 'patch', endpoints: ["/v1.0/users/#{mailbox}#{calendar_path(calendargroup_id, calendar_id)}/events/#{booking_id}"], data: event_json)
            check_response(request)
        rescue Microsoft::Error::Conflict => e
            return {}
        end
        Microsoft::Office2::Event.new(client: self, event: JSON.parse(request.body)).event
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
            return 200
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

    def create_event_json(subject: nil, body: nil, start_param: nil, end_param: nil, timezone: nil, rooms: nil, location: nil, attendees: nil, organizer_name: nil, organizer:nil, recurrence: nil, is_private: nil, showAs: 'busy', responseRequested: true)
        event_json = {}
        event_json[:showAs] = showAs
        event_json[:responseRequested] = responseRequested
        event_json[:subject] = subject if subject
        event_json[:attendees] = attendees if attendees
        
        event_json[:sensitivity] = ( is_private ? "private" : "normal" ) if is_private

        event_json[:body] = {
            contentType: "HTML",
            content: (body || "")
        }

        if start_param
            start_date = Time.at(start_param).to_datetime.in_time_zone(timezone)
            event_json[:start] = {
                dateTime: start_date.strftime('%FT%R'),
                timeZone: timezone
            }
        end

        if end_param
            end_date   = Time.at(end_param).to_datetime.in_time_zone(timezone)
            event_json[:end] = {
                dateTime: end_date.strftime('%FT%R'),
                timeZone: timezone
            }
        end

        # Put the attendees into the MS Graph expected format
        attendees&.map! do |a|
            attendee_type = ( a[:optional] ? "optional" : "required" )
            { emailAddress: { address: a[:email], name: a[:name] }, type: attendee_type }
        end

        # Add each room to the attendees array
        rooms&.each do |room|
            attendees.push({ type: "resource", emailAddress: { address: room[:email], name: room[:name] } })
        end


        event_json[:organizer] = {
            emailAddress: {
                address: organizer[:email],
                name: organizer[:email] || organizer[:email]
            }
        } if organizer

        # If we have rooms then use that, otherwise use the location string
        if rooms
            event_json[:locations] = rooms.map { |r| { displayName: r[:name] } }
        elsif location
            event_json[:locations] = [{displayName: location}]
        end

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
