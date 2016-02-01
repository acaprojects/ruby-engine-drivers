module Microsoft; end

class Microsoft::FindMe
    include ::Orchestrator::Constants


    # Discovery Information
    uri_base 'https://findme.companyname.com'
    descriptive_name 'Microsoft FindMe Service'
    generic_name :FindMe

    # Communication settings
    keepalive true
    inactivity_timeout 15000


    def on_load
        @fullnames = {}
        @meetings = {}
        @meetings_checked = {}

        on_update
    end
    
    def on_update
        # Configure NTLM authentication
        config({
            ntlm: {
                user: setting(:username),
                password: setting(:password),
                domain: setting(:domain)
            }
        })

        # The environment this is used in has insane latency
        defaults(timeout: 15000)
    end
    
    
    # ============
    # GET REQUESTS
    # ============
    def levels
        # Example Response: [{"Building":"SYDNEY","Level":"0","Online":13},{"Building":"SYDNEY","Level":"2","Online":14},
        #                    {"Building":"SYDNEY","Level":"3","Online":18}]
        get('/FindMeService/api/MeetingRooms/BuildingLevelsWithMeetingRooms', name: :levels) do |data|
            check_resp(data) do |result|
                buildings = {}
                result.each do |level|
                    building_name = level[:Building]
                    buildings[building_name] ||= []
                    buildings[building_name] << level[:Level]
                end

                self[:buildings] = buildings
                self[:levels] = result
            end
        end
    end

    def rooms(building, level)
        # Example Response:
        # [{"Alias":"cf2020","Name":"Minogue","Building":"SYDNEY","Level":"2","LocationDescription":"2020",
        #   "X":null,"Y":null,"Capacity":4,"Features":null,"CanBeBooked":true,"PhotoUrl":null,"HasAV":false,
        #   "HasDeskPhone":true,"HasSpeakerPhone":false,"HasWhiteboard":true}]
        get("/FindMeService/api/MeetingRooms/Level/#{building}/#{level}", name: :rooms) do |data|
            check_resp(data) do |result|
                self["#{building}_#{level}"] = result

                result.each do |room|
                    self["room_#{room[:Alias]}"] = room
                end
            end
        end
    end

    def meetings(building, level, start_time = Time.now, end_time = Time.now.end_of_day)
        lookup = :"#{building}_#{level}"
        last_checked = @meetings_checked[lookup]

        if last_checked && last_checked > Time.now
            return @meetings[lookup]
        else
            defer = thread.defer

            start_str = Time.parse(start_time.to_s).iso8601.split('+')[0]
            end_str = Time.parse(end_time.to_s).iso8601.split('+')[0]

            @meetings_checked[lookup] = 5.minutes.from_now
            @meetings[lookup] = defer.promise

            # Example Response:
            # [{"ConferenceRoomAlias":"cfsydinx","Start":"2015-11-11T23:30:00+00:00","End":"2015-11-12T00:00:00+00:00",
            #   "Subject":"<meeting title>","Location":"Pty MR Syd L2 INXS (10) RT Int","BookingUserAlias":null,
            #   "StartTimeZoneName":null,"EndTimeZoneName":null}]
            promise = get("/FindMeService/api/MeetingRooms/Meetings/#{building}/#{level}/#{start_str}/#{end_str}") do |data|
                check_resp(data) do |result|
                    defer.resolve result
                end
            end
            promise.catch do
                @meetings_checked.delete lookup
                @meetings.delete lookup
                defer.reject "request failed"
            end

            defer.promise
        end
    end

    def user_details(*users)
        # Example Response:
        # [{"Alias":"dwatson","LastUpdate":"2015-11-12T02:25:50.017Z","Confidence":100,
        #   "Coordinates":{"Building":"SYDNEY","Level":"2","X":76,"Y":29,"LocationDescription":"2140","MapByLocationId":true},
        #   "GPS":{"Latitude":-33.796597429,"Longitude":151.1382508278,"Accuracy":0.0,"LocationDescription":null},
        #   "LocationIdentifier":null,"Status":"Located","LocatedUsing":"FixedLocation","Type":"Person","Comments":null,
        #   "ExtendedUserData":{"Alias":"dwatson","DisplayName":"David Watson","EmailAddress":"David.Watson@microsoft.com","LyncSipAddress":"dwatson@microsoft.com"}}]
        get("/FindMeService/api/ObjectLocation/Users/#{users.join(',')}", name: :users) do |data|
            check_resp(data) do |users|
                users.each do |user|
                    self["user_#{user[:Alias]}"] = user
                end
            end
        end
    end

    def users_on(building, level, extended_data = false)
        defer = thread.defer

        # Same response as above with or without ExtendedUserData
        uri = "/FindMeService/api/ObjectLocation/Level/#{building}/#{level}"
        uri << '?getExtendedData=true' if extended_data

        get(uri) do |data|
            check_resp(data) do |users|
                defer.resolve users
            end
        end

        defer.promise
    end

    def users_fullname(username)
        defer = thread.defer

        if @fullnames[username]
            defer.resolve @fullnames[username]
        else

            # Supports comma seperated usernames however we'll only request one at a time
            # Example Response: ['name1', 'name2']
            get("/FindMeService/api/User/FullNames?param=#{username}", name: :users) do |data|
                check_resp(data) do |users|
                    @fullnames[username] = users[0]
                    defer.resolve users[0]
                end
            end
        end

        defer.promise
    end

    def user_image(login_name)
        defer = thread.defer

        # Returns binary JPEG image
        get("/FindMeService/api/User/Photo/#{login_name}", name: :users) do |data|
            if data[:headers].status == 200
                defer.resolve data[:body]
                :success
            else
                :failed
            end
        end

        defer.promise
    end


    # =============
    # POST REQUESTS
    # =============
    def schedule_meeting(user_alias, room_alias, start_time, end_time, subject = 'Room Booked')
        # Check this booking can be made
        # Make the booking

        start_str = Time.parse(start_time.to_s).iso8601.split('+')[0]
        end_str = Time.parse(end_time.to_s).iso8601.split('+')[0]

        details = self["room_#{room_alias}"]
        location = if details
            "Building #{details[:Building]} level #{details[:Level]}, room #{details[:Name]}"
        else
            "Room #{room_alias}"
        end

        post('/FindMeService/api/MeetingRooms/ScheduleMeeting', {
            body: {
                :ConferenceRoomAlias => room_alias,
                :Start => start_str,
                :End => end_str,
                :Subject => subject,
                :Location => location,
                :BookingUserAlias => user_alias,
                :StartTimeZoneName => "AUS Eastern Standard Time",
                :EndTimeZoneName => "AUS Eastern Standard Time"
            }
        }) do |data|
            if data[:headers].status == 200
                :success
            else
                :failed
            end
        end
    end


    protected


    # JSON decode options
    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze

    def check_resp(data)
        if data[:headers].status == 200
            yield ::JSON.parse(data[:body], DECODE_OPTIONS)
            :success
        else
            :failed
        end
    end
end
