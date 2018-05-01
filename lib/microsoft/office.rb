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
    TIMEZONE_MAPPING = {
        "Sydney": "AUS Eastern Standard Time"
    }
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
            delegated:false,
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
        @delegated = delegated
        oauth_options = { site: @app_site,  token_url: @app_token_url }
        oauth_options[:connection_opts] = { proxy: @internet_proxy } if @internet_proxy
        @graph_client ||= OAuth2::Client.new(
            @client_id,
            @client_secret,
            oauth_options
        )
    end 

    def graph_token
       @graph_token ||= @graph_client.client_credentials.get_token({
            :scope => @app_scope
        }).token
    end

    def password_graph_token
        @graph_token ||= @graph_client.password.get_token(
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

        log_graph_request(request_method, data, query, headers, graph_path, password)


        graph_api_options = {inactivity_timeout: 25000}
        if @internet_proxy
            proxy = URI.parse(@internet_proxy)
            graph_api_options[:proxy] = { host: proxy.host, port: proxy.port }
        end

        graph_api = UV::HttpEndpoint.new(@graph_domain, graph_api_options)
        response = graph_api.__send__(request_method, path: graph_path, headers: headers, body: data, query: query)

        start_timing = Time.now.to_i
        response_value = response.value
        end_timing = Time.now.to_i
        STDERR.puts "Graph request took #{end_timing - start_timing} seconds"
        STDERR.flush
        return response_value
    end

    def log_graph_request(request_method, data, query, headers, graph_path, password)
        STDERR.puts "--------------NEW GRAPH REQUEST------------"
        STDERR.puts "#{request_method} to #{graph_path}"
        STDERR.puts "Data:"
        STDERR.puts data if data
        STDERR.puts "Query:"
        STDERR.puts query if query
        STDERR.puts "Headers:"
        STDERR.puts headers if headers
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

    def get_users(q: nil, limit: nil)
        if q.include?(" ")
            queries = q.split(" ")
            filter_params = []
            queries.each do |q|
                filter_params.push("(startswith(displayName,'#{q}') or startswith(givenName,'#{q}') or startswith(surname,'#{q}') or startswith(mail,'#{q}') or startswith(userPrincipalName,'#{q}'))")
            end
            filter_param = filter_params.join(" or ")
        else
            filter_param = "startswith(displayName,'#{q}') or startswith(givenName,'#{q}') or startswith(surname,'#{q}') or startswith(mail,'#{q}') or startswith(userPrincipalName,'#{q}')" if q
        end
        query_params = {
            '$filter': filter_param,
            '$top': limit
        }.compact
        endpoint = "/v1.0/users"
        request = graph_request(request_method: 'get', endpoint: endpoint, query: query_params, password: @delegated)
        check_response(request)
        JSON.parse(request.body)['value']
    end

    def get_user(user_id:)
        endpoint = "/v1.0/users/#{user_id}"
        request = graph_request('get', endpoint)
        check_response(request)
        JSON.parse(request.body)
    end

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

    def get_room(room_id:)
        endpoint = "/beta/users/#{@service_account_email}/findRooms"
        request = graph_request(request_method: 'get', endpoint: endpoint, password: true)
        check_response(request)
        room_response = JSON.parse(request.body)['value']
        room_response.select! { |room| room['email'] == room_id }
    end

    def get_available_rooms(room_ids:, start_param:, end_param:, attendees:[])
        endpoint = "/v1.0/users/#{@service_account_email}/findMeetingTimes" 
        now = Time.now
        start_ruby_param = ensure_ruby_date((start_param || now))
        end_ruby_param = ensure_ruby_date((end_param || (now + 1.hour)))
        duration_string = "PT#{end_ruby_param.to_i-start_ruby_param.to_i}S"
        start_param = start_ruby_param.utc.iso8601.split("+")[0]
        end_param = (end_ruby_param + 30.minutes).utc.iso8601.split("+")[0]

        # Add the attendees
        attendees.map!{|a|
            { 
                type: 'required',
                emailAddress: {
                    address: a[:email],
                    name: a[:name]
            }   }
        }

        location_constraint = {
            isRequired: true,
            locations: room_ids.map{ |email| 
                {
                    locationEmailAddress: email, 
                    resolveAvailability: true
                }
            },
            suggestLocation: false
        }

        time_constraint = {
            activityDomain: 'unrestricted',
            timeslots: [{
                start: {
                    DateTime: start_param,
                    TimeZone: 'UTC'
                },
                end: {
                    DateTime: end_param,
                    TimeZone: 'UTC'
                }
            }]
        }

        post_data = {
            attendees: attendees,
            locationConstraint: location_constraint,
            timeConstraint: time_constraint,
            maxCandidates: 1000,
            returnSuggestionReasons: true,
            meetingDuration: duration_string


        }.to_json

        request = graph_request(request_method: 'post', endpoint: endpoint, data: post_data, password: true)
        check_response(request)
        JSON.parse(request.body)
    end

    def delete_booking(room_id:, booking_id:)
        room = Orchestrator::ControlSystem.find(room_id)
        endpoint = "/v1.0/users/#{room.email}/events/#{booking_id}"
        request = graph_request(request_method: 'delete', endpoint: endpoint, password: @delegated)
        check_response(request)
        response = JSON.parse(request.body)
    end

    def get_bookings_by_user(user_id:, start_param:Time.now, end_param:(Time.now + 1.week))
        # Allow passing in epoch, time string or ruby Time class
        start_param = ensure_ruby_date(start_param).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).iso8601.split("+")[0]

        # Array of all bookings within our period
        recurring_bookings = get_recurring_bookings_by_user(user_id, start_param, end_param)

        endpoint = "/v1.0/users/#{user_id}/events"
        
        query_hash = {}
        query_hash['$top'] = "200"

        # Build our query to only get bookings within our datetimes
        if not start_param.nil?
            query_hash['$filter'.to_sym] = "(Start/DateTime le '#{start_param}' and End/DateTime ge '#{start_param}') or (Start/DateTime ge '#{start_param}' and Start/DateTime le '#{end_param}')"
        end

        bookings_response = graph_request(request_method: 'get', endpoint: endpoint, query: query_hash, password: @delegated)
        check_response(bookings_response)
        bookings = JSON.parse(bookings_response.body)['value']
        if bookings.nil?
            return recurring_bookings
        else
            bookings.concat recurring_bookings
        end
    end

    def get_recurring_bookings_by_user(user_id, start_param=Time.now, end_param=(Time.now + 1.week))
        # Allow passing in epoch, time string or ruby Time class
        start_param = ensure_ruby_date(start_param).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).iso8601.split("+")[0]

        recurring_endpoint = "/v1.0/users/#{user_id}/calendarView"

        # Build our query to only get bookings within our datetimes
        query_hash = {}
        query_hash['$top'] = "200"

        if not start_param.nil?
            query_hash['startDateTime'] = start_param
            query_hash['endDateTime'] = end_param
        end

        recurring_response = graph_request(request_method: 'get', endpoint: recurring_endpoint, query: query_hash, password: @delegated)
        check_response(recurring_response)
        recurring_bookings = JSON.parse(recurring_response.body)['value']
    end

    def get_bookings_by_room(room_id:, start_param:Time.now, end_param:(Time.now + 1.week))
        return get_bookings_by_user(room_id: room_id, start_param: start_param, end_param: end_param)
    end


    def create_booking(room_id:, start_param:, end_param:, subject:, description:nil, current_user:, attendees: nil, recurrence: nil, timezone:'Sydney')
        description = String(description)
        attendees = Array(attendees)

        # Get our room
        room = Orchestrator::ControlSystem.find(room_id)

        # Set our endpoint with the email
        endpoint = "/v1.0/users/#{room.email}/events"

        # Ensure our start and end params are Ruby dates and format them in Graph format
        start_object = ensure_ruby_date(start_param).in_time_zone(timezone)
        end_object = ensure_ruby_date(end_param).in_time_zone(timezone)
        start_param = ensure_ruby_date(start_param).in_time_zone(timezone).iso8601.split("+")[0]
        end_param = ensure_ruby_date(end_param).in_time_zone(timezone).iso8601.split("+")[0]


        # Add the attendees
        attendees.map!{|a|
            { emailAddress: {
                    address: a[:email],
                    name: a[:name]
            }   }
        }

        # Add the room as an attendee
        attendees.push({
            type: "resource",
            emailAddress: {
                address: room.email,
                name: room.name
            }
        })

        # Add the current user as an attendee
        attendees.push({
            emailAddress: {
                address: current_user[:email],
                name: current_user[:name]
            }
        })

        # Create our event which will eventually be stringified
        event = {
            subject: subject,
            body: {
                contentType: 'html',
                content: description
            },
            start: {
                dateTime: start_param,
                timeZone: TIMEZONE_MAPPING[timezone.to_sym]
            },
            end: {
                dateTime: end_param,
                timeZone: TIMEZONE_MAPPING[timezone.to_sym]
            },
            location: {
                displayName: room.name,
                locationEmailAddress: room.email
            },
            isOrganizer: false,
            organizer: {
                emailAddress: {
                    address: current_user.email,
                    name: current_user.name
                }
            },
            attendees: attendees
        }

        if recurrence
            event[:recurrence] = {
                pattern: {
                    type: recurrence,
                    interval: 1,
                    daysOfWeek: [start_object.strftime("%A")]
                },
                range: {
                    type: 'noEnd',
                    startDate: start_object.strftime("%F")
                }
            }
        end

        event = event.to_json

        request = graph_request(request_method: 'post', endpoint: endpoint, data: event, password: @delegated)

        check_response(request)

        response = JSON.parse(request.body)
    end

    def update_booking(booking_id:, room_id:, start_param:nil, end_param:nil, subject:nil, description:nil, attendees:nil, timezone:'Sydney')
        # We will always need a room and endpoint passed in
        room = Orchestrator::ControlSystem.find(room_id)
        endpoint = "/v1.0/users/#{room.email}/events/#{booking_id}"
        STDERR.puts "ENDPOINT IS"
        STDERR.puts endpoint
        STDERR.flush
        event = {}
        event[:subject] = subject if subject

        event[:start] = {
            dateTime: start_param,
            timeZone: TIMEZONE_MAPPING[timezone.to_sym]
        } if start_param

        event[:end] = {
            dateTime: end_param,
            timeZone: TIMEZONE_MAPPING[timezone.to_sym]
        } if end_param

        event[:body] = {
            contentType: 'html',
            content: description
        } if description

        # Let's assume that the request has the current user and room as an attendee already
        event[:attendees] = attendees.map{|a|
            { emailAddress: {
                    address: a[:email],
                    name: a[:name]
            }   }
        } if attendees

        request = graph_request(request_method: 'patch', endpoint: endpoint, data: event.to_json, password: @delegated)
        check_response(request)
        response = JSON.parse(request.body)['value']
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
