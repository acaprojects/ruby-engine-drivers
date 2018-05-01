# Reference: https://www.ibm.com/developerworks/lotus/library/ls-Domino_URL_cheat_sheet/

require 'active_support/time'
require 'logger'
module Ibm; end

class Ibm::Domino
    def initialize(
            username:,
            password:,
            auth_hash:,
            domain:,
            timezone:,
            logger: Logger.new(STDOUT)
        )
        @domain = domain
        @timeone = timezone
        @logger = logger
        @headers = {
            'Authorization' => "Basic #{auth_hash}",
            'Content-Type' => 'application/json'
        }
        @domino_api = UV::HttpEndpoint.new(@domain, {inactivity_timeout: 25000, keepalive: false})
    end

    def domino_request(request_method, endpoint, data = nil, query = {}, headers = {}, full_path = nil)
        # Convert our request method to a symbol and our data to a JSON string
        request_method = request_method.to_sym
        data = data.to_json if !data.nil? && data.class != String

        @headers.merge(headers) if headers
        
        if full_path
            if full_path.include?('/api/calendar/')
                uri = URI.parse(full_path)
            else
                uri = URI.parse(full_path + '/api/calendar/events')
            end  
            domino_api = UV::HttpEndpoint.new("https://#{uri.host}", {inactivity_timeout: 25000})
            domino_path = uri.to_s
        elsif request_method == :post
            domino_api = UV::HttpEndpoint.new(ENV['DOMINO_CREATE_DOMAIN'], {inactivity_timeout: 25000})
            domino_path = "#{ENV['DOMINO_CREATE_DOMAIN']}#{endpoint}"
        else
            domino_api = @domino_api
            domino_path = "#{ENV['DOMINO_DOMAIN']}#{endpoint}"
        end

        @logger.info "------------NEW DOMINO REQUEST--------------"
        @logger.info domino_path
        @logger.info query
        @logger.info data
        @logger.info @headers
        @logger.info "--------------------------------------------"

        response = domino_api.__send__(request_method, path: domino_path, headers: @headers, body: data, query: query)
    end

    def get_free_rooms(starting, ending)
        starting = convert_to_simpledate(starting)
        ending = convert_to_simpledate(ending)        

        starting = starting.utc
        ending = ending.utc

        req_params = {
            :site => ENV["DOMINO_SITE"],
            :start => to_ibm_date(starting),
            :end => to_ibm_date(ending),
            :capacity => 1
        }

        res = domino_request('get','/api/freebusy/freerooms', nil, req_params).value
        domino_emails = JSON.parse(res.body)['rooms']
    end

    def get_users_bookings_created_today(database)
        user_bookings = get_users_bookings(database, nil, nil, 1)
        user_bookings.select!{ |booking|
            if booking.key?('last-modified')
                booking['last-modified'] && Time.now.midnight < booking['last-modified'] && Time.now.tomorrow.midnight > booking['last-modified']
            else
                false
            end
        }
        user_bookings
        
        rescue => e
            STDERR.puts "#{e.message}\n#{e.backtrace.join("\n")}"
        raise e
    end

    def get_users_bookings(database,  date=nil, simple=nil, weeks=1)

        if !date.nil?
            # Make date a date object from epoch or parsed text
            date = convert_to_simpledate(date).utc
            starting = to_ibm_date(date)
            ending = to_ibm_date(date.tomorrow)
        else
            starting = to_ibm_date(Time.now.midnight.utc)
            ending = to_ibm_date((Time.now.midnight.utc + weeks.week))
        end

        query = {
            before: ending,
            since: starting
        }

        events = []
        # First request is to the user's database
        request = domino_request('get', nil, nil, query, nil, database).value
        if [200,201,204].include?(request.status) 
            if request.body != ''
                events = add_event_utc(JSON.parse(request.body))
            end
        else
            return nil
        end

        query = {
            since: starting
        }

        invite_db = database + '/api/calendar/invitations'
        request = domino_request('get', nil, nil, query, nil, invite_db).value
        if [200,201,204].include?(request.status) 
            if request.body != ''
                invites = JSON.parse(request.body)['events']
                events += invites if !invites.nil?
            end
        else
            return nil
        end

        full_events = []
        events.each{ |event|
            db_uri = URI.parse(database)
            base_domain = db_uri.scheme + "://" + db_uri.host

            if simple
                # If we're dealing with an invite we must try and resolve the href
                if !event.key?('start')
                    invite = get_attendees(base_domain + event['href'])
                    if invite
                        full_events.push({
                            start: invite['start'],
                            end: invite['end']
                        })
                    end
                else
                    full_events.push({
                        start: event['start'],
                        end: event['end']
                    })
                end
                next
            end
            full_event = get_attendees(base_domain + event['href'])
            
            if full_event == false
                full_event = event
                full_event['organizer'] = {}
                full_event['description'] = ''
                full_event['attendees'] = []
            end
            full_events.push(full_event)
        }
        full_events
        
    rescue => e
            STDERR.puts "\n\n#{e.message}\n#{e.backtrace.join("\n")}\n\n"
        raise "\n\n#{e.message}\n#{e.backtrace.join("\n")}\n\n"
    end

    def get_booking(path, database)
        db_uri = URI.parse(database)
        base_domain = db_uri.scheme + "://" + db_uri.host
        event_path = base_domain + path
        booking_request = domino_request('get',nil,nil,nil,nil,event_path).value
        if ![200,201,204].include?(booking_request.status)
            @logger.info "Didn't get a 20X response from meeting detail requst."
            return false
        end
        return JSON.parse(booking_request.body)['events'][0]
    end

    def get_bookings(room_ids, date=Time.now.midnight, ending=nil, full_data=false)
        room_ids = Array(room_ids)
        room_names = room_ids.map{|id| Orchestrator::ControlSystem.find(id).settings['name']}
        room_mapping = {}
        room_ids.each{|id|
            room_mapping[Orchestrator::ControlSystem.find(id).settings['name']] = id
        }

        # The domino API takes a StartKey and UntilKey
        # We will only ever need one days worth of bookings
        # If startkey = 2017-11-29 and untilkey = 2017-11-30
        # Then all bookings on the 30th (the day of the untilkey) are returned

        # Make date a date object from epoch or parsed text
        date = convert_to_simpledate(date)
        starting = date.utc.strftime("%Y%m%dT%H%M%S,00Z")

        if ending
            ending = convert_to_simpledate(ending).utc.strftime("%Y%m%dT%H%M%S,00Z")
        else
            ending = date.tomorrow.utc.strftime("%Y%m%dT%H%M%S,00Z")
        end


        # Set count to max
        query = {
            Count: '500',
            StartKey: starting,
            UntilKey: ending,
            KeyType: 'time',
            ReadViewEntries: nil,
            OutputFormat: 'JSON'
        }

        # Get our bookings 
        request = domino_request('get', "/RRDB.nsf/93FDE1776546DEEB482581E7000B27FF", nil, query)
        response = request.value

        if full_data
            uat_server = UV::HttpEndpoint.new(ENV['ALL_USERS_DOMAIN'])
            all_users = uat_server.get(path: ENV['ALL_USERS_PATH']).value
            all_users = JSON.parse(all_users.body)['staff']
        end

        # Go through the returned bookings and add to output array
        rooms_bookings = {}
        room_ids.each{|id|
            rooms_bookings[id] = []
        }
        bookings = JSON.parse(response.body)['viewentry'] || []
        @logger.info "Checking room names:"
        @logger.info room_names
        start_timer = Time.now
        bookings.each{ |booking|

            # Get the room name
            domino_room_name = booking['entrydata'][2]['text']['0']

            # Check if room is in our list
            if room_names.include?(domino_room_name)
                organizer = booking['entrydata'][3]['text']['0']
                new_booking = {
                    start: Time.parse(booking['entrydata'][0]['datetime']['0']).to_i * 1000,
                    end: Time.parse(booking['entrydata'][1]['datetime']['0']).to_i * 1000,
                    summary: booking['entrydata'][5]['text']['0'],
                    organizer: organizer
                }
                if full_data
                    booking_id = booking['entrydata'][9]['text']['0']
                    staff_db = nil
                    all_users.each{|u|
                        if u['StaffLNMail'] == organizer
                            staff_db = "https://#{u['ServerName']}/#{u['MailboxPath']}.nsf"
                            break
                        end
                    }
                    staff_db_uri = URI.parse(staff_db)
                    path = "#{staff_db_uri.path}/api/calendar/events/#{booking_id}"
                    new_booking[:database] = staff_db
                    new_booking[:path] = path
                end
                rooms_bookings[room_mapping[domino_room_name]].push(new_booking)
            end
        }
        end_timer = Time.now
        @logger.info "Total time #{end_timer - start_timer}"
        rooms_bookings
    end


    def create_booking(current_user:, starting:, ending:, database:, room_id:, summary:, description: nil, organizer:, attendees: [], timezone: @timezone, **opts)
        room = Orchestrator::ControlSystem.find(room_id)
        starting = convert_to_simpledate(starting)
        ending = convert_to_simpledate(ending)        
        event = {
            :summary => summary,
            :class => :public,
            :start => to_utc_date(starting),
            :end => to_utc_date(ending)
        }

        if description.nil?
            description = ""
        end

        # if room.support_url
           # description = description + "\nTo control this meeting room, click here: #{room.support_url}"
        event[:description] = description
        # end

        event[:attendees] = Array(attendees).collect do |attendee|
            out_attendee = {
                role: "req-participant",
                status: "needs-action",
                rsvp: true,
                email: attendee[:email]
            }
            out_attendee[:displayName] = attendee[:name] if attendee[:name]
            out_attendee
        end

        # Set the current user as orgaqnizer and chair if no organizer passed in
        if organizer
            event[:organizer] = {
                email: organizer[:email]
            }
            event[:organizer][:displayName] = organizer[:name] if organizer[:name]

            event[:attendees].push({
                 "role":"chair",
                 "status":"accepted",
                 "rsvp":false,
                 "email": organizer[:email]
            })
        else
            event[:organizer] = {
                email: current_user.email
            }
            event[:attendees].push({
                 "role":"chair",
                 "status":"accepted",
                 "rsvp":false,
                 "email": current_user.email
            })
        end

        # Add the room as an attendee
        event[:attendees].push({
             "role":"chair",
             "status":"accepted",
             "rsvp":false,
             "userType":"room",
             "email": room.email
        })


        request = domino_request('post', nil, {events: [event]}, nil, nil, database).value
        request
    end



    def delete_booking(database, id)
        request = domino_request('delete', nil, nil, nil, nil, "#{database}/api/calendar/events/#{id}").value
    end


    def edit_booking(id:, current_user: nil, starting:, ending:, database:, room_email:, summary:, description: nil, organizer:, attendees: [], timezone: @timezone, **opts)
        room = Orchestrator::ControlSystem.find_by_email(room_email)
        starting = convert_to_simpledate(starting)        
        ending = convert_to_simpledate(ending)        
        event = {
            :summary => summary,
            :class => :public,
            :start => to_utc_date(starting),
            :end => to_utc_date(ending),
            # :href => "/#{database}/api/calendar/events/#{id}",
            :id => id
        }

        if description.nil?
            description = ""
        end

        # if room.support_url
            # description = description + "\nTo control this meeting room, click here: #{room.support_url}"
            event[:description] = description
        # end

        event[:attendees] = Array(attendees).collect do |attendee|
            out_attendee = {
                role: "req-participant",
                status: "needs-action",
                rsvp: true,
                email: attendee[:email]
            }
            out_attendee[:displayName] = attendee[:name] if attendee[:name]
            out_attendee
        end

        if current_user.nil?
             event[:organizer] = {
                email: organizer
            }
            event[:attendees].push({
                 "role":"chair",
                 "status":"accepted",
                 "rsvp":false,
                 "email": organizer
            })
        else
            # Organizer will not change
            event[:organizer] = {
                email: current_user.email
            }
            event[:attendees].push({
                 "role":"chair",
                 "status":"accepted",
                 "rsvp":false,
                 "email": current_user.email
            })
        end

        # Add the room as an attendee
        event[:attendees].push({
             "role":"chair",
             "status":"accepted",
             "rsvp":false,
             "userType":"room",
             "email": room.email
        })


        request = domino_request('put', nil, {events: [event]}, {workflow: true}, nil, database + "/api/calendar/events/#{id}").value
        request
    end

    def get_attendees(path)
        booking_request = domino_request('get',nil,nil,nil,nil,path).value
        if ![200,201,204].include?(booking_request.status)
            @logger.info "Didn't get a 20X response from meeting detail requst."
            return false
        end

        booking_response = add_event_utc(JSON.parse(booking_request.body))[0]
        room = get_system(booking_response)
        
        if room
            room_id = room.id
            support_url = room.support_url
        else
            room_id = nil
            support_url = nil
        end

        if booking_response['attendees']

            declined = !(is_accepted(booking_response))
            booking_response['attendees'].each{|attendee|
                if attendee.key?('userType') && attendee['userType'] == 'room'
                    booking_response['room_email'] = attendee['email']
                else
                    booking_response['room_email'] = nil
                end
            }
            attendees = booking_response['attendees'].dup 
            attendees.map!{ |attendee|
                if attendee['status'] == 'accepted'
                    accepted = true
                else
                    accepted = false
                end
                if attendee.key?('displayName')
                    attendee_name = attendee['displayName']
                else
                    attendee_name = attendee['email']
                end
                if attendee.key?('userType') && attendee['userType'] == 'room'
                    next
                end

                {
                    name: attendee_name,
                    email: attendee['email'],
                    state: attendee['status'].gsub(/-/,' ')
                }
            }.compact!
            booking_response['attendees'] = attendees
        end

        if booking_response['organizer']
            organizer = booking_response['organizer'].dup 
            organizer = 
            {
                name: organizer['displayName'],
                email: organizer['email'],
                accepted: true
            }            
            booking_response['organizer'] = organizer
        end

        booking_response['start_readable'] = Time.at(booking_response['start'].to_i / 1000).to_s
        booking_response['end_readable'] = Time.at(booking_response['end'].to_i / 1000).to_s
        booking_response['support_url'] = support_url if support_url
        booking_response['room_id'] = room_id if room_id
        booking_response['declined'] = true if declined
        booking_response['location'] = "Unassigned" if declined
        booking_response['room_email'] = nil if declined
        booking_response['room_id'] = nil if declined
        booking_response
    end

    def is_accepted(event)
        accepted = true
        event['attendees'].each{|attendee|
            if attendee.key?('userType') && attendee['userType'] == 'room'
                if attendee.key?('status') && attendee['status'] == 'declined'
                    accepted = false
                end
            end
        }
        return accepted
    end


    def get_system(booking)
        @@elastic ||= Elastic.new(Orchestrator::ControlSystem)

        # Deal with a date range query
        elastic_params = ActionController::Parameters.new({})
        elastic_params[:q] = "\"#{booking['location']}\""
        elastic_params[:limit] = 500


        # Find the room with the email ID passed in
        filters = {}
        query = @@elastic.query(elastic_params, filters)
        matching_rooms = @@elastic.search(query)[:results]
        return matching_rooms[0]

    end

    def add_event_utc(response)

        events = response['events']
        response.key?('timezones') ? timezones = response['timezones'] : timezones = nil

        events.reject!{|event|
            if event.key?('summary')
                event['summary'][0..10] == "Invitation:"
            end
        }
        events.each{ |event|
            # If the event has no time, set time to "00:00:00"
            if !event['start'].key?('time')
                start_time = "00:00:00"
                end_time = "00:00:00"
                start_date = event['start']['date']
                end_date = event['end']['date']
            elsif !event.key?('end')
                start_time = event['start']['time']
                end_time = event['start']['time']
                start_date = event['start']['date']
                end_date = event['start']['date']
            else
                start_time = event['start']['time']
                end_time = event['end']['time']
                start_date = event['start']['date']
                end_date = event['end']['date']
            end

            # If the event start has a tzid field, use the timezones hash
            if event['start'].key?('tzid')
                offset = timezones.find{|t| t['tzid'] == event['start']['tzid']}['standard']['offsetFrom']

            # If the event has a utc field set to true, use utc
            elsif event['start'].key?('utc') && event['start']['utc']
                offset = "+0000"
            end

            start_timestring = "#{start_date}T#{start_time}#{offset}"
            start_utc = (Time.parse(start_timestring).utc.to_i.to_s + "000").to_i

            end_timestring = "#{end_date}T#{end_time}#{offset}"
            end_utc = (Time.parse(end_timestring).utc.to_i.to_s + "000").to_i

            event['start'] = start_utc
            event['end'] = end_utc
        }
        events    
    end

    # Take a time object and convert to a string in the format IBM uses
    def to_ibm_date(time)
        time.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    # Takes a date of any kind (epoch, string, time object) and returns a time object
    def convert_to_simpledate(date) 
        if !(date.class == Time)
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

    # Take a time object and return a hash in the format LN uses
    def to_utc_date(time)
        utctime = time.getutc
        {
            date: utctime.strftime("%Y-%m-%d"),
            time: utctime.strftime("%H:%M:%S"),
            utc: true
        }
    end

end
