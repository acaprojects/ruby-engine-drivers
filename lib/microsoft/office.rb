require 'active_support/time'
require 'logger'

module Microsoft
    class Error < StandardError
        class ResourceNotFound < Error; end
        class InvalidAuthenticationToken < Error; end
        class BadRequest < Error; end
        class ErrorInvalidIdMalformed < Error; end
        class ErrorAccessDenied < Error; end
    end
end

class Microsoft::Office
    # TIMEZONE_MAPPING = {
    #     "Sydney": "AUS Eastern Standard Time",
    #     "Brisbane": "Australia/Brisbane",
    #     "HK": "Asia/Hong_Kong",
    #     "Hong_Kong": "Asia/Hong_Kong",
    #     "UTC": "UTC"
    # }
    def initialize(
            client_id:,
            client_secret:,
            app_site:,
            app_token_url:,
            app_scope:,
            graph_domain:,
            service_account_email:,
            service_account_password:,
            internet_proxy:nil,
            permission: 'impersonation',
            mailbox_location: 'user',
            logger: Rails.logger
        )
        @client_id = client_id
        @client_secret = client_secret
        @app_site = app_site
        @app_token_url = app_token_url
        @app_scope = app_scope
        @graph_domain = graph_domain
        @service_account_email = service_account_email
        @service_account_password = service_account_password
        @internet_proxy = internet_proxy
        @permission = permission
        @mailbox_location = mailbox_location
        @delegated = false
        oauth_options = { site: @app_site,  token_url: @app_token_url }
        oauth_options[:connection_opts] = { proxy: @internet_proxy } if @internet_proxy
        @graph_client ||= OAuth2::Client.new(
            @client_id,
            @client_secret,
            oauth_options
        )
    end

    def graph_token
       @graph_token = @graph_client.client_credentials.get_token({
            :scope => @app_scope
        }).token
    end

    def password_graph_token
        @graph_token = @graph_client.password.get_token(
        @service_account_email,
        @service_account_password,
        {
            :scope => @app_scope
        }).token
    end

    def graph_request(request_method:, endpoint:, data:nil, query:{}, headers:nil, password:false)
        headers = Hash(headers)
        query = Hash(query)
        # Convert our request method to a symbol and our data to a JSON string
        request_method = request_method.to_sym
        data = data.to_json if !data.nil? && data.class != String

        if password
            headers['Authorization'] = "Bearer #{password_graph_token}"
        else
            headers['Authorization'] = "Bearer #{graph_token}"
        end

        # Set our unchanging headers
        headers['Content-Type'] = ENV['GRAPH_CONTENT_TYPE'] || "application/json"
        headers['Prefer'] = ENV['GRAPH_PREFER'] || 'outlook.timezone="Australia/Sydney"'

        graph_path = "#{@graph_domain}#{endpoint}"

        if Rails.env != 'test'
            log_graph_request(request_method, data, query, headers, graph_path, password)
        end


        graph_api_options = {inactivity_timeout: 25000, keepalive: false}
        if @internet_proxy
            proxy = URI.parse(@internet_proxy)
            graph_api_options[:proxy] = { host: proxy.host, port: proxy.port }
        end

        graph_api = UV::HttpEndpoint.new(@graph_domain, graph_api_options)
        response = graph_api.__send__(request_method, path: graph_path, headers: headers, body: data, query: query)

        start_timing = Time.now.to_i
        response_value = response.value
        end_timing = Time.now.to_i
        return response_value
    end


    def bulk_graph_request(request_method:, endpoints:, data:nil, query:nil, headers:nil, password:false)
        query = Hash(query)
        headers = Hash(headers)

        if password
            headers['Authorization'] = "Bearer #{password_graph_token}"
        else
            headers['Authorization'] = "Bearer #{graph_token}"
        end

        # Set our unchanging headers
        headers['Content-Type'] = ENV['GRAPH_CONTENT_TYPE'] || "application/json"
        headers['Prefer'] = ENV['GRAPH_PREFER'] || 'outlook.timezone="Australia/Sydney"'

        graph_path = "#{@graph_domain}/v1.0/$batch"
        query_string = "?#{query.map { |k,v| "#{k}=#{v}" }.join('&')}"

        request_array = []
        endpoints.each_with_index do |endpoint, i|
            request_array.push({
                id: i,
                method: request_method.upcase,
                url: "#{endpoint}#{query_string}"
            })
        end
        bulk_data = {
            requests: request_array
        }.to_json

        graph_api_options = {inactivity_timeout: 25000, keepalive: false}

        if @internet_proxy
            proxy = URI.parse(@internet_proxy)
            graph_api_options[:proxy] = { host: proxy.host, port: proxy.port }
        end

        if Rails.env != 'test'
            log_graph_request(request_method, bulk_data, query, headers, graph_path, password, endpoints)
        end

        graph_api = UV::HttpEndpoint.new(@graph_domain, graph_api_options)
        response = graph_api.__send__('post', path: graph_path, headers: headers, body: bulk_data)

        start_timing = Time.now.to_i
        response_value = response.value
        end_timing = Time.now.to_i
        return response_value
    end


    def log_graph_request(request_method, data, query, headers, graph_path, password, endpoints=nil)
        STDERR.puts "--------------NEW GRAPH REQUEST------------"
        STDERR.puts "#{request_method} to #{graph_path}"
        STDERR.puts "Data:"
        STDERR.puts data if data
        STDERR.puts "Query:"
        STDERR.puts query if query
        STDERR.puts "Headers:"
        STDERR.puts headers if headers
        STDERR.puts "Endpoints:"
        STDERR.puts endpoints if endpoints
        STDERR.puts "Password auth is: #{password}"
        STDERR.puts '--------------------------------------------'
        STDERR.flush
    end

    def check_response(response)
        case response.status
        when 200, 201, 204
            return
        when 400
            if response['error']['code'] == 'ErrorInvalidIdMalformed'
                raise Microsoft::Error::ErrorInvalidIdMalformed.new(response.body)
            else
                raise Microsoft::Error::BadRequest.new(response.body)
            end
        when 401
            raise Microsoft::Error::InvalidAuthenticationToken.new(response.body)
        when 403
            raise Microsoft::Error::ErrorAccessDenied.new(response.body)
        when 404
            raise Microsoft::Error::ResourceNotFound.new(response.body)
        end
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_list
    def get_users(q: nil, limit: nil, contact_email:nil)

        # If we have a query and the query has at least one space
        if q && q.include?(" ")
            # Split it into word tokens
            queries = q.split(" ")
            filter_params = []
            # For each word, create a filtering statement
            queries.each do |q|
                filter_params.push("(startswith(displayName,'#{q}') or startswith(givenName,'#{q}') or startswith(surname,'#{q}') or startswith(mail,'#{q}'))")
            end
            # Join these filtering statements using 'or' and add accountEnabled filter
            filter_param = "(accountEnabled eq true) and #{filter_params.join(" and ")}"
        else
            filter_param = "(accountEnabled eq true) and (startswith(displayName,'#{q}') or startswith(givenName,'#{q}') or startswith(surname,'#{q}') or startswith(mail,'#{q}'))" if q
        end
        filter_param = "accountEnabled eq true" if q.nil?
        query_params = {
            '$filter': filter_param,
            '$top': limit
        }.compact
        endpoint = "/v1.0/users"
        request = graph_request(request_method: 'get', endpoint: endpoint, query: query_params, password: @delegated)
        check_response(request)
        user_list = JSON.parse(request.body)['value']
        user_list += self.get_contacts(owner_email:contact_email) if contact_email
        user_list
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_get
    def get_user(user_id:)
        endpoint = "/v1.0/users/#{user_id}"
        request = graph_request(request_method: 'get', endpoint: endpoint, password: @delegated)
        check_response(request)
        JSON.parse(request.body)
    end

    def has_user(user_id:)
        endpoint = "/v1.0/users/#{user_id}"
        request = graph_request(request_method: 'get', endpoint: endpoint, password: @delegated)
        if [200, 201, 204].include?(request.status)
            return true
        else
            return false
        end
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_list_contacts
    def get_contacts(owner_email:, q:nil, limit:nil)
        query_params = { '$top': (limit || 1000) }
        query_params['$filter'] = "startswith(displayName, '#{q}') or startswith(givenName, '#{q}') or startswith(surname, '#{q}') or emailAddresses/any(a:a/address eq  '#{q}')" if q
        endpoint = "/v1.0/users/#{owner_email}/contacts"
        request = graph_request(request_method: 'get', endpoint: endpoint, query: query_params, password: @delegated)
        check_response(request)
        return format_contacts(JSON.parse(request.body)['value'], owner_email)
    end

    def format_contacts(contacts, host)
        output_contacts = []
        contacts.each do |contact|
            if contact.key?('emailAddresses') && !contact['emailAddresses'].empty?
                output_format = {}
                output_format[:id] = contact['id']
                output_format[:first_name] = contact['givenName']
                output_format[:last_name] = contact['surname']
                output_format[:phone] = contact['businessPhones'][0]
                output_format[:organisation] = contact['companyName']
                output_format[:email] = contact['emailAddresses'][0]['address']
                output_format[:title] = contact['title']
                output_format[:host] = host
                output_format[:purpose] = "Here to see #{host}"
                output_contacts.push(output_format)
            end
        end
        output_contacts
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_list_contacts
    def get_contact(owner_email:, contact_email:nil)
        endpoint = "/v1.0/users/#{owner_email}/contacts"
        if contact_email
            query_params = {
                '$top': 1,
                '$filter': "emailAddresses/any(a:a/address eq  '#{contact_email}')"
            }
        else
            query_params = { '$top': 999 }
        end

        request = graph_request(request_method: 'get', endpoint: endpoint, query: query_params, password: @delegated)
        check_response(request)
        JSON.parse(request.body)['value']
    end

    def get_contact_by_id(owner_email:, contact_id:)
        endpoint = "/v1.0/users/#{owner_email}/contacts/#{contact_id}"
        request = graph_request(request_method: 'get', endpoint: endpoint, password: @delegated)
        JSON.parse(request.body)
    end

    def has_contact(owner_email:, contact_email:)
        return get_contact(owner_email: owner_email, contact_email: contact_email).length > 0
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_post_contacts
    def add_contact(owner_email:, email:, first_name:, last_name:, phone:nil, organisation:nil, other:{}, title:"")
        # This data is required so add it unconditionally
        contact_data = {
            title: title,
            givenName: first_name,
            surname: last_name,
            emailAddresses: [{
                address: email,
                name: "#{first_name} #{last_name}"
            }]
        }

        # Only add these fields if passed in
        contact_data[:businessPhones] = [ phone ] if phone
        contact_data[:companyName] = organisation if organisation
        other.each do |field, value|
            contact_data[field.to_sym] = value
        end


        endpoint = "/v1.0/users/#{owner_email}/contacts"
        request = graph_request(request_method: 'post', endpoint: endpoint, data: contact_data, password: @delegated)
        check_response(request)
        JSON.parse(request.body)
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_list_contacts
    def get_organisations(owner_email:)
        query_params = {
            '$top': 1000
        }
        endpoint = "/v1.0/users/#{owner_email}/contacts"
        request = graph_request(request_method: 'get', endpoint: endpoint, query: query_params, password: @delegated)
        check_response(request)
        contacts = JSON.parse(request.body)['value']
        orgs = []
        contacts.each do |cont| orgs.push(cont['companyName']) if !cont['companyName'].nil? && !cont['companyName'].empty? end
        orgs.uniq.compact
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/beta/api/user_findrooms
    def get_rooms(q: nil, limit: nil)
        filter_param = "startswith(name,'#{q}') or startswith(address,'#{q}')" if q
        query_params = {
            '$filter': filter_param,
            '$top': limit
        }.compact
        endpoint = "/beta/users/#{@service_account_email}/findRooms"
        request = graph_request(request_method: 'get', endpoint: endpoint, query: query_params, password: @delegated)
        check_response(request)
        room_response = JSON.parse(request.body)['value']
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/beta/api/user_findrooms
    def get_room(room_id:)
        endpoint = "/beta/users/#{@service_account_email}/findRooms"
        request = graph_request(request_method: 'get', endpoint: endpoint, password: true)
        check_response(request)
        room_response = JSON.parse(request.body)['value']
        room_response.select! { |room| room['email'] == room_id }
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/beta/api/user_findmeetingtimes
    def get_available_rooms(rooms:, start_param:, end_param:)
        endpoint = "/v1.0/users/#{@service_account_email}/findMeetingTimes"
        now = Time.now
        start_ruby_param = ensure_ruby_date((start_param || now))
        end_ruby_param = ensure_ruby_date((end_param || (now + 1.hour)))
        duration_string = "PT#{end_ruby_param.to_i-start_ruby_param.to_i}S"
        start_param = start_ruby_param.utc.iso8601.split("+")[0]
        end_param = end_ruby_param.utc.iso8601.split("+")[0]

        # Add the attendees
        rooms.map!{|room|
            {
                type: 'required',
                emailAddress: {
                    address: room[:email],
                    name: room[:name]
            }   }
        }

        time_constraint = {
            activityDomain: 'unrestricted',
            timeslots: [{
                start: {
                    dateTime: start_param,
                    TimeZone: 'UTC'
                },
                end: {
                    dateTime: end_param,
                    timeZone: 'UTC'
                }
            }]
        }

        post_data = {
            attendees: rooms,
            timeConstraint: time_constraint,
            maxCandidates: 1000,
            returnSuggestionReasons: true,
            meetingDuration: duration_string,
            isOrganizerOptional: true


        }.to_json

        request = graph_request(request_method: 'post', endpoint: endpoint, data: post_data, password: true)
        check_response(request)
        JSON.parse(request.body)
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/event_get
    def get_booking(booking_id:, mailbox:, icaluid:nil, extensions:[])
        if icaluid && booking_id.nil?

            # Build our query to only get bookings within our datetimes
            query_hash = {}
            query_hash['$filter'] = "iCalUId eq '#{icaluid}'"
            query_hash['$expand'] = "extensions($filter=id eq '#{extensions[0]}')"
            endpoint = "/v1.0/users/#{mailbox}/events"
            request = graph_request(request_method: 'get', endpoint: endpoint, password: @delegated, query: query_hash)
        else
            endpoint = "/v1.0/users/#{mailbox}/events/#{booking_id}"
            if extensions
                query_hash = { '$expand': "extensions($filter=id eq '#{extensions[0]}')" }
                request = graph_request(request_method: 'get', endpoint: endpoint, password: @delegated, query: query_hash)
            else
                request = graph_request(request_method: 'get', endpoint: endpoint, password: @delegated)
            end
        end
        check_response(request)
        JSON.parse(request.body)
    end

    def accept_booking(booking_id:, mailbox:, comment:nil)
        endpoint = "/v1.0/users/#{mailbox}/events/#{booking_id}/accept"
        params = {
            request_method: 'post',
            endpoint: endpoint,
            password: @delegated
        }
        params[:data] = { comment: comment } if comment
        request = graph_request(params)
        check_response(request)
        return true

    end
    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/event_delete
    def delete_booking(booking_id:, mailbox:)
        endpoint = "/v1.0/users/#{mailbox}/events/#{booking_id}"
        request = graph_request(request_method: 'delete', endpoint: endpoint, password: @delegated)
        check_response(request)
        200
    end

    # https://docs.microsoft.com/en-us/graph/api/event-decline?view=graph-rest-1.0
    def decline_meeting(booking_id:, mailbox:, comment: )
        endpoint = "/v1.0/users/#{mailbox}/events/#{booking_id}/decline"
        comment = 'The booking was removed from this room as the host did not Start the meeting via the booking panel' if comment.nil?
        request = graph_request(request_method: 'post', endpoint: endpoint, password: @delegated, data: {comment: comment})
        check_response(request)
        200
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/event_delete
    def delete_contact(contact_id:, mailbox:)
        endpoint = "/v1.0/users/#{mailbox}/events/#{contact_id}"
        request = graph_request(request_method: 'delete', endpoint: endpoint, password: @delegated)
        check_response(request)
        200
    end

    def get_bookings_created_from(mailboxes:, created_from:)
        mailboxes = Array(mailboxes)
        created_from = ensure_ruby_date(created_from).utc.iso8601

        all_endpoints = mailboxes.map do |email|
            "/users/#{email}/events"
        end

        slice_size = 20
        responses = []
        all_endpoints.each_slice(slice_size).with_index do |endpoints, ind|
            query = {
                '$top': 200,
                '$filter': "createdDateTime gt #{created_from}"
            }

            bulk_response = bulk_graph_request(request_method: 'get', endpoints: endpoints, query: query )

            check_response(bulk_response)
            parsed_response = JSON.parse(bulk_response.body)['responses']
            parsed_response.each do |res|
                local_id = res['id'].to_i
                global_id = local_id + (slice_size * ind.to_i)
                res['id'] = global_id
                responses.push(res)
            end
        end

        bookings = {}
        responses.each_with_index do |res, i|
            bookings[mailboxes[res['id'].to_i]] = []
            res['body']['value'].each do |booking|
                bookings[mailboxes[res['id'].to_i]].push(format_booking_data(booking, mailboxes[res['id'].to_i]))
            end
        end
        bookings
    end

    def get_bookings_by_user(user_id:, start_param:Time.now, end_param:(Time.now + 1.month), available_from: Time.now, available_to: (Time.now + 1.hour), bulk: false, availability: true, internal_domain:nil, ignore_booking: nil, extensions:[], custom_query:[])
        # The user_ids param can be passed in as a string or array but is always worked on as an array
        user_id = Array(user_id)

        # Allow passing in epoch, time string or ruby Time class
        start_param = ensure_ruby_date(start_param).utc.iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).utc.iso8601.split("+")[0]
        available_from = ensure_ruby_date(available_from).utc.iso8601.split("+")[0]
        available_to = ensure_ruby_date(available_to).utc.iso8601.split("+")[0]

        # Array of all bookings within our period
        if bulk
            recurring_bookings = bookings_request_by_users(user_id, start_param, end_param, extensions, custom_query)
        else
            recurring_bookings = bookings_request_by_user(user_id, start_param, end_param, extensions)
        end

        recurring_bookings.each do |u_id, bookings|
            is_available = true
            bookings.each_with_index do |booking, i|
                bookings[i] = extract_booking_data(booking, available_from, available_to, u_id, internal_domain, extensions)
                if bookings[i]['free'] == false && bookings[i]['icaluid'] != ignore_booking
                    is_available = false
                end
            end
            recurring_bookings[u_id] = {available: is_available, bookings: bookings}
        end

        if bulk
            return recurring_bookings
        else
            if availability
                return recurring_bookings[user_id[0]]
            else
                return recurring_bookings[user_id[0]][:bookings]
            end
        end
    end

    def format_booking_data(booking, room_email, internal_domain=nil, extensions=[])
        room = Orchestrator::ControlSystem.find_by_email(room_email)

        # Create time objects of the start and end for easier use
        booking_start = ActiveSupport::TimeZone.new(booking['start']['timeZone']).parse(booking['start']['dateTime'])
        booking_end = ActiveSupport::TimeZone.new(booking['end']['timeZone']).parse(booking['end']['dateTime'])

        if room
            if room.settings.key?('setup')
                booking_start_with_setup = booking_start - room.settings['setup'].to_i.seconds
            else
                booking_start_with_setup = booking_start
            end

            if room.settings.key?('breakdown')
                booking_end_with_setup = booking_end + room.settings['breakdown'].to_i.seconds
            else
                booking_end_with_setup = booking_end
            end
        end


        # Grab the start and end in the right format for the frontend
        # booking['Start'] = booking_start.utc.iso8601
        # booking['End'] = booking_end.utc.iso8601
        booking['start_epoch'] = booking_start.to_i
        booking['end_epoch'] = booking_end.to_i

        # Get some data about the booking
        booking['title'] = booking['subject']
        booking['booking_id'] = booking['id']
        booking['icaluid'] = booking['iCalUId']
        booking['show_as'] = booking['showAs']
        booking['created'] = booking['createdDateTime']

        if booking.key?('extensions') && !extensions.empty?
            booking['extensions'].each do |ext|
                if extensions.map {|e| "Microsoft.OutlookServices.OpenTypeExtension.#{e}"}.include?(ext['id'])
                    ext.each do |ext_key, ext_val|
                        booking[ext_key] = ext_val if !['@odata.type', 'id','extensionName'].include?(ext_key)
                    end
                end
            end
        end

        # Check whether this event has external attendees
        booking_has_visitors = false

        # Format the attendees and save the old format
        new_attendees = []
        booking['attendees'].each do |attendee|
            attendee_email = attendee['emailAddress']['address']
            if attendee['type'] == 'resource'
                booking['room_id'] = attendee_email.downcase
            else
                # Check if attendee is external or internal
                if booking.key?('owner')
                    internal_domains = [ ::Mail::Address.new(booking['owner']).domain ]
                else
                    internal_domains = ENV['INTERNAL_DOMAIN'].split(",") || internal_domain
                end
                mail_object = ::Mail::Address.new(attendee_email)
                mail_domain = mail_object.domain
                booking_has_visitors = true if not internal_domains.include?(mail_domain)
                attendee_object = {
                    email: attendee_email,
                    name: attendee['emailAddress']['name'],
                    visitor: !internal_domains.include?(mail_domain),
                    organisation: attendee_email.split('@')[1..-1].join("").split('.')[0].capitalize
                }
                new_attendees.push(attendee_object)
            end
        end
        booking['visitors'] = booking_has_visitors
        booking['old_attendees'] = booking['attendees']
        booking['attendees'] = new_attendees

        # Get the organiser and location data
        if booking.key?('owner') && booking.key?('owner_name')
            booking['organizer'] = { name: booking['owner_name'], email: booking['owner']}
        else
            booking['organizer'] = { name: booking['organizer']['emailAddress']['name'], email: booking['organizer']['emailAddress']['address']}
        end
        # if !booking.key?('room_id') && booking['locations'] && !booking['locations'].empty? && booking['locations'][0]['uniqueId']
        #     booking['room_id'] = booking['locations'][0]['uniqueId'].downcase
        # end
        # booking['room_id'] = room_email
        if !booking['location']['displayName'].nil? && !booking['location']['displayName'].empty?
            booking['room_name'] = booking['location']['displayName']
        end

        booking_info = User.bucket.get("bookinginfo-#{booking['iCalUId']}", quiet: true)
        if booking_info
            booking['catering'] = booking_info[:catering] if booking_info.key?(:catering)
            booking['parking'] = booking_info[:parking] if booking_info.key?(:parking)
            booking['notes'] = booking_info[:notes] if booking_info.key?(:notes)
            booking['food_ordered'] = booking_info[:food_ordered] if booking_info.key?(:food_ordered)
            booking['walk_in'] = booking_info[:walk_in] if booking_info.key?(:walk_in)
            booking['event'] = booking_info[:event] if booking_info.key?(:event)
            booking['check_ins'] = booking_info[:check_ins] if booking_info.key?(:check_ins)
        end


        booking
    end

    def extract_booking_data(booking, start_param, end_param, room_email, internal_domain=nil, extensions=[])
        room = Orchestrator::ControlSystem.find_by_email(room_email)

        # Create time objects of the start and end for easier use
        booking_start = ActiveSupport::TimeZone.new(booking['start']['timeZone']).parse(booking['start']['dateTime'])
        booking_end = ActiveSupport::TimeZone.new(booking['end']['timeZone']).parse(booking['end']['dateTime'])

        if room
            if room.settings.key?('setup')
                booking_start_with_setup = booking_start - room.settings['setup'].to_i.seconds
            else
                booking_start_with_setup = booking_start
            end

            if room.settings.key?('breakdown')
                booking_end_with_setup = booking_end + room.settings['breakdown'].to_i.seconds
            else
                booking_end_with_setup = booking_end
            end
        end

        # Check if this means the room is unavailable
        booking_overlaps_start = (booking_start_with_setup || booking_start) < start_param && (booking_end_with_setup || booking_end) > start_param
        booking_in_between = (booking_start_with_setup || booking_start) >= start_param && (booking_end_with_setup || booking_end) <= end_param
        booking_overlaps_end = (booking_start_with_setup || booking_start) < end_param && (booking_end_with_setup || booking_end) > end_param
        if booking_overlaps_start || booking_in_between || booking_overlaps_end
            booking['free'] = false
        else
            booking['free'] = true
        end

        # Grab the start and end in the right format for the frontend
        # booking['Start'] = booking_start.utc.iso8601
        # booking['End'] = booking_end.utc.iso8601
        booking['start_epoch'] = booking_start.to_i
        booking['end_epoch'] = booking_end.to_i

        # Get some data about the booking
        booking['title'] = booking['subject']
        booking['booking_id'] = booking['id']
        booking['icaluid'] = booking['iCalUId']
        booking['show_as'] = booking['showAs']
        booking['created'] = booking['createdDateTime']

        if booking.key?('extensions') && !extensions.empty?
            booking['extensions'].each do |ext|
                if extensions.map {|e| "Microsoft.OutlookServices.OpenTypeExtension.#{e}"}.include?(ext['id'])
                    ext.each do |ext_key, ext_val|
                        booking[ext_key] = ext_val if !['@odata.type', 'id','extensionName'].include?(ext_key)
                    end
                end
            end
        end

        # Check whether this event has external attendees
        booking_has_visitors = false

        # Format the attendees and save the old format
        new_attendees = []
        booking['room_id'] = []
        booking['attendees'].each do |attendee|
            attendee_email = attendee['emailAddress']['address']
            if attendee['type'] == 'resource'
                booking['room_id'].push(attendee_email.downcase) if Orchestrator::ControlSystem.find_by_email(attendee_email.downcase)
            else
                # Check if attendee is external or internal
                if booking.key?('owner')
                    internal_domains = [::Mail::Address.new(booking['owner']).domain]
                else
                    internal_domains = ENV['INTERNAL_DOMAIN'].split(",") || internal_domain
                end
                mail_object = ::Mail::Address.new(attendee_email)
                mail_domain = mail_object.domain
                booking_has_visitors = true if not internal_domains.include?(mail_domain)
                attendee_object = {
                    email: attendee_email,
                    name: attendee['emailAddress']['name'],
                    visitor: !internal_domains.include?(mail_domain),
                    organisation: attendee_email.split('@')[1..-1].join("").split('.')[0].capitalize
                }
                new_attendees.push(attendee_object)
            end
        end

        booking['visitors'] = booking_has_visitors
        booking['old_attendees'] = booking['attendees']
        booking['attendees'] = new_attendees

        # Get the organiser and location data
        if booking.key?('owner') && booking.key?('owner_name')
            booking['organizer'] = { name: booking['owner_name'], email: booking['owner']}
        else
            booking['organizer'] = { name: booking['organizer']['emailAddress']['name'], email: booking['organizer']['emailAddress']['address']}
        end
        # if !booking.key?('room_id') && booking['locations'] && !booking['locations'].empty? && booking['locations'][0]['uniqueId']
        #     booking['room_id'] = booking['locations'][0]['uniqueId'].downcase
        # end
        # booking['room_id'] = room_email
        if !booking['location']['displayName'].nil? && !booking['location']['displayName'].empty?
            booking['room_name'] = booking['location']['displayName']
        end

        booking_info = User.bucket.get("bookinginfo-#{booking['iCalUId']}", quiet: true)
        if booking_info
            booking['catering'] = booking_info[:catering] if booking_info.key?(:catering)
            booking['parking'] = booking_info[:parking] if booking_info.key?(:parking)
            booking['notes'] = booking_info[:notes] if booking_info.key?(:notes)
            booking['food_ordered'] = booking_info[:food_ordered] if booking_info.key?(:food_ordered)
            booking['walk_in'] = booking_info[:walk_in] if booking_info.key?(:walk_in)
            booking['event'] = booking_info[:event] if booking_info.key?(:event)
            booking['check_ins'] = booking_info[:check_ins] if booking_info.key?(:check_ins)
        end


        booking
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_list_calendarview
    def bookings_request_by_user(user_id, start_param=Time.now, end_param=(Time.now + 1.week), extensions=[])
        if user_id.class == Array
            user_id = user_id[0]
        end
        # Allow passing in epoch, time string or ruby Time class
        start_param = ensure_ruby_date(start_param).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).iso8601.split("+")[0]

        recurring_endpoint = "/v1.0/users/#{user_id}/calendarView"

        # Build our query to only get bookings within our datetimes
        query_hash = {}
        query_hash['$top'] = "200"
        extensions.each do |ext_name|
            query_hash['$expand'] = "Extensions($filter=id eq 'Microsoft.OutlookServices.OpenTypeExtension.#{ext_name}')"
        end
        if not start_param.nil?
            query_hash['startDateTime'] = start_param
            query_hash['endDateTime'] = end_param
        end

        recurring_response = graph_request(request_method: 'get', endpoint: recurring_endpoint, query: query_hash, password: @delegated)
        check_response(recurring_response)
        recurring_bookings = {}
        recurring_bookings[user_id] = JSON.parse(recurring_response.body)['value']
        recurring_bookings
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_list_calendarview
    def bookings_request_by_users(user_ids, start_param=Time.now, end_param=(Time.now + 1.week), extensions=[], custom_query=[])
        # Allow passing in epoch, time string or ruby Time class
        start_param = ensure_ruby_date(start_param).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).iso8601.split("+")[0]

        all_endpoints = user_ids.map do |email|
            "/users/#{email}/calendarView"
        end
        slice_size = 20
        responses = []
        all_endpoints.each_slice(slice_size).with_index do |endpoints, ind|
            query = {
                '$top': 10000,
                startDateTime: start_param,
                endDateTime: end_param,
            }
            extensions.each do |ext_name|
                query['$expand'] = "Extensions($filter=id eq 'Microsoft.OutlookServices.OpenTypeExtension.#{ext_name}')"
            end

            custom_query.each do |query_key, query_val|
                query[query_key] = query_val
            end

            bulk_response = bulk_graph_request(request_method: 'get', endpoints: endpoints, query: query )

            check_response(bulk_response)
            parsed_response = JSON.parse(bulk_response.body)['responses']
            parsed_response.each do |res|
                local_id = res['id'].to_i
                global_id = local_id + (slice_size * ind.to_i)
                res['id'] = global_id
                responses.push(res)
            end
        end

        recurring_bookings = {}
        responses.each_with_index do |res, i|
            recurring_bookings[user_ids[res['id'].to_i]] = res['body']['value']
        end
        recurring_bookings
    end

    def get_bookings_by_room(room_id:, start_param:Time.now, end_param:(Time.now + 1.week))
        return get_bookings_by_user(user_id: room_id, start_param: start_param, end_param: end_param)
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/user_post_events
    def create_booking(room_id:, start_param:, end_param:, subject:, description:nil, current_user:, attendees: nil, recurrence: nil, recurrence_end: nil, is_private: false, timezone:'UTC', endpoint_override:nil, content_type:"HTML", extensions:[], location:nil, add_current_user: true)
        description = String(description)
        attendees = Array(attendees)

        if room_id.class != Array
            room_id = [room_id]
        end

        # Get our room
        rooms = room_id.map do |r_id|
            Orchestrator::ControlSystem.find_by_id(r_id) || Orchestrator::ControlSystem.find_by_email(r_id)
        end


        if endpoint_override
            endpoint = "/v1.0/users/#{endpoint_override}/events"
        elsif @mailbox_location == 'room' || current_user.nil?
            endpoint = "/v1.0/users/#{rooms[0].email}/events"
        elsif @mailbox_location == 'user'
            endpoint = "/v1.0/users/#{current_user[:email]}/events"
        end

        # Get the timezones out of the room's zone if it has any
        rooms[0].zones.each do |zone_id|
            zone = Orchestrator::Zone.find(zone_id)
            if zone.settings.key?("timezone")
                timezone = zone.settings['timezone']
            end
        end


        # Ensure our start and end params are Ruby dates and format them in Graph format
        start_object = ensure_ruby_date(start_param).in_time_zone(timezone)
        end_object = ensure_ruby_date(end_param).in_time_zone(timezone)
        start_param = ensure_ruby_date(start_param).in_time_zone(timezone).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).in_time_zone(timezone).iso8601.split("+")[0]
        recurrence_end = ensure_ruby_date(recurrence_end)

        # Add the attendees
        attendees.map!{|a|
            if a[:optional]
                attendee_type = 'optional'
            else
                attendee_type = 'required'
            end
            { emailAddress: {
                    address: a[:email],
                    name: a[:name]
            },
                type: attendee_type
            }
        }

        rooms.each do |room|
            # Add the room as an attendee
            attendees.push({
                type: "resource",
                emailAddress: {
                    address: room.email,
                    name: room.name
                }
            })
        end

        # Add the current user as an attendee
        if current_user && add_current_user
            attendees.push({
                emailAddress: {
                    address: current_user[:email],
                    name: current_user[:name]
                }
            })
        end

        # Create our event which will eventually be stringified
        event = {
            subject: subject,
            body: {
                contentType: content_type,
                content: "X!X!X!"
            },
            start: {
                dateTime: start_param,
                timeZone: timezone
            },
            end: {
                dateTime: end_param,
                timeZone: timezone
            },
            location: {
                displayName: rooms.map{|room| room.name}.join(" and "),
                locationEmailAddress: rooms[0].id
            },
            isOrganizer: false,
            attendees: attendees
        }
        event[:location][:displayName] = location if location
        exts = []
        extensions.each do |extension|
            ext = {
                "@odata.type": "microsoft.graph.openTypeExtension",
                "extensionName": extension[:name]
            }
            extension[:values].each do |ext_key, ext_value|
                ext[ext_key] = ext_value
            end
            exts.push(ext)
        end
        event[:extensions] = exts

        if current_user
            event[:organizer] = {
                emailAddress: {
                    address: current_user[:email],
                    name: current_user[:name]
                }
            }
        else
            event[:organizer] = {
                emailAddress: {
                    address: rooms[0].email,
                    name: rooms[0].name
                }
            }
        end

        if recurrence
            recurrence_range = {
                type: 'endDate',
                startDate: start_object.strftime("%F"),
                endDate: recurrence_end.strftime("%F")
            }
            STDERR.puts "Creating recurrence with details:"
            STDERR.puts recurrence_range
            STDERR.puts "In timezone: #{timezone}"
            STDERR.flush
            event[:recurrence] = {
                pattern: {
                    type: recurrence,
                    interval: 1,
                    daysOfWeek: [start_object.strftime("%A")]
                },
                range: recurrence_range
            }
        end

        if is_private
            event[:sensitivity] = 'private'
        end

        event = event.to_json

        event.gsub!("X!X!X!",description)

        request = graph_request(request_method: 'post', endpoint: endpoint, data: event, password: @delegated)

        check_response(request)

        response = JSON.parse(request.body)
        format_booking_data(response, rooms[0].email)
    end

    # https://developer.microsoft.com/en-us/graph/docs/api-reference/v1.0/api/event_update
    def update_booking(booking_id:, room_id:, start_param:nil, end_param:nil, subject:nil, description:nil, attendees:nil, current_user:nil, timezone:'Australia/Sydney', endpoint_override:nil, extensions:nil)
        # We will always need a room and endpoint passed in
        room = Orchestrator::ControlSystem.find_by_email(room_id) || Orchestrator::ControlSystem.find(room_id)


        if endpoint_override
            endpoint = "/v1.0/users/#{endpoint_override}/events/#{booking_id}"
        elsif @mailbox_location == 'room' || current_user.nil?
            endpoint = "/v1.0/users/#{room.email}/events/#{booking_id}"
        elsif @mailbox_location == 'user'
            endpoint = "/v1.0/users/#{current_user[:email]}/events/#{booking_id}"
        end



        start_object = ensure_ruby_date(start_param).in_time_zone(timezone)
        end_object = ensure_ruby_date(end_param).in_time_zone(timezone)
        start_param = ensure_ruby_date(start_param).in_time_zone(timezone).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).in_time_zone(timezone).iso8601.split("+")[0]

        # Get the timezone out of the room's zone if it has any
        room.zones.each do |zone_id|
            zone = Orchestrator::Zone.find(zone_id)
            if zone.settings.key?("timezone")
                timezone = zone.settings['timezone']
            end
        end

        event = {}
        event[:subject] = subject if subject

        event[:start] = {
            dateTime: start_param,
            timeZone: timezone
        } if start_param

        event[:end] = {
            dateTime: end_param,
            timeZone: timezone
        } if end_param

        event[:location] = {
            displayName: room.name,
            locationEmailAddress: room.email
        }

        event[:body] = {
            contentType: 'html',
            content: "X!X!X!"
        } if description

        # Let's assume that the request has the current user and room as an attendee already
        event[:attendees] = attendees.map{|a|
            {
                emailAddress: {
                    address: a[:email],
                    name: a[:name]
                }
            }
        } if attendees

        event[:attendees] ||= []

        event[:attendees].push({
            emailAddress: {
                address: room.email,
                name: room.name
            },
            type: 'resource'
        })

        exts = []
        extensions.each do |extension|
            ext = {
                "@odata.type": "microsoft.graph.openTypeExtension",
                "extensionName": extension[:name]
            }
            extension[:values].each do |ext_key, ext_value|
                ext[ext_key] = ext_value
            end
            exts.push(ext)
        end
        event[:extensions] = exts


        event = event.to_json

        event.gsub!("X!X!X!",description) if description

        request = graph_request(request_method: 'patch', endpoint: endpoint, data: event, password: @delegated)
        check_response(request)
        response = JSON.parse(request.body)
        format_booking_data(response, room.email)
    end

    def check_in_attendee(owner_email:, attendee_email:, icaluid:, response_type:'Accepted')
        # Do whatever this client requires upon checking
        # VisitorEmail.deliver
        user_details = self.get_contact(owner_email:owner_email, contact_email:attendee_email)
        # Mark this user as checked in
        booking_info = (User.bucket.get("bookinginfo-#{icaluid}", quiet: true) || {}).dup
        booking_info[:check_ins] ||= []
        booking_info[:check_ins].push(attendee_email)
        User.bucket.set("bookinginfo-#{icaluid}", booking_info)
        return user_details
    end


    # Takes a date of any kind (epoch, string, time object) and returns a time object
    def ensure_ruby_date(date)
        if !(date.class == Time || date.class == DateTime)
            if string_is_digits(date)

                # Convert to an integer
                date = date.to_i

                # If JavaScript epoch remove milliseconds
                if date.to_s.length == 13
                    date /= 1000
                end

                # Convert to datetimes
                date = Time.at(date)
            else
                date = Time.parse(date)
            end
        end
        return date
    end

    # Returns true if a string is all digits (used to check for an epoch)
    def string_is_digits(string)
        string = string.to_s
        string.scan(/\D/).empty?
    end

end
