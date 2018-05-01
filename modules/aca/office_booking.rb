# encoding: ASCII-8BIT

require 'faraday'
require 'uv-rays'
require 'microsoft/office'
Faraday.default_adapter = :libuv

# For rounding up to the nearest 15min
# See: http://stackoverflow.com/questions/449271/how-to-round-a-time-down-to-the-nearest-15-minutes-in-ruby
class ActiveSupport::TimeWithZone
    def ceil(seconds = 60)
        return self if seconds.zero?
        Time.at(((self - self.utc_offset).to_f / seconds).ceil * seconds).in_time_zone + self.utc_offset
    end
end


module Aca; end

# NOTE:: Requires Settings:
# ========================
# room_alias: 'rs.au.syd.L16Aitken',
# building: 'DP3',
# level: '16'

class Aca::OfficeBooking
    include ::Orchestrator::Constants
    EMAIL_CACHE = ::Concurrent::Map.new
    CAN_LDAP = begin
        require 'net/ldap'
        true
    rescue LoadError
        false
    end
    CAN_OFFICE = begin
        require 'oauth2'
        true
    rescue LoadError
        false
    end


    descriptive_name 'Office365 Room Bookings'
    generic_name :Bookings
    implements :logic


    # The room we are interested in
    default_settings({
        update_every: '2m',

        # Moved to System or Zone Setting
        # cancel_meeting_after: 900

        # Card reader IDs if we want to listen for swipe events
        card_readers: ['reader_id_1', 'reader_id_2'],

        # Optional LDAP creds for looking up emails
        ldap_creds: {
            host: 'ldap.org.com',
            port: 636,
            encryption: {
                method: :simple_tls,
                tls_options: {
                    verify_mode: 0
                }
            },
            auth: {
                  method: :simple,
                  username: 'service account',
                  password: 'password'
            }
        },
        tree_base: "ou=User,ou=Accounts,dc=org,dc=com",

        # Optional EWS for creating and removing bookings
        ews_creds: [
            'https://company.com/EWS/Exchange.asmx',
            'service account',
            'password',
            { http_opts: { ssl_verify_mode: 0 } }
        ],
        ews_room: 'room@email.address',

        # Optional EWS for creating and removing bookings
        office_organiser_location: 'attendees'
        # office_client_id: ENV["OFFICE_APP_CLIENT_ID"],
        # office_secret: ENV["OFFICE_APP_CLIENT_SECRET"],
        # office_scope: ENV['OFFICE_APP_SCOPE'],
        # office_site: ENV["OFFICE_APP_SITE"],
        # office_token_url: ENV["OFFICE_APP_TOKEN_URL"],
        # office_options: {
        #     site: ENV["OFFICE_APP_SITE"],
        #     token_url: ENV["OFFICE_APP_TOKEN_URL"]
        # },
        # office_room: 'room@email.address'
    })


    def on_load
        on_update
    end

    def on_update
        self[:swiped] ||= 0
        @last_swipe_at = 0
        @use_act_as = setting(:use_act_as)

        self[:hide_all] = setting(:hide_all) || false
        self[:touch_enabled] = setting(:touch_enabled) || false
        self[:name] = self[:room_name] = setting(:room_name) || system.name

        self[:control_url] = setting(:booking_control_url) || system.config.support_url
        self[:booking_controls] = setting(:booking_controls)
        self[:booking_catering] = setting(:booking_catering)
        self[:booking_hide_details] = setting(:booking_hide_details)
        self[:booking_hide_availability] = setting(:booking_hide_availability)
        self[:booking_hide_user] = setting(:booking_hide_user)
        self[:booking_hide_description] = setting(:booking_hide_description)
        self[:booking_hide_timeline] = setting(:booking_hide_timeline)

        # Skype join button available 2min before the start of a meeting
        @skype_start_offset = setting(:skype_start_offset) || 120

        # Skype join button not available in the last 8min of a meeting
        @skype_end_offset = setting(:skype_end_offset) || 480

        # Because restarting the modules results in a 'swipe' of the last read card
        ignore_first_swipe = true

        # Is there catering available for this room?
        self[:catering] = setting(:catering_system_id)
        if self[:catering]
            self[:menu] = setting(:menu)
        end

        # Do we want to look up the users email address?
        if CAN_LDAP
            @ldap_creds = setting(:ldap_creds)
            if @ldap_creds
                encrypt = @ldap_creds[:encryption]
                encrypt[:method] = encrypt[:method].to_sym if encrypt && encrypt[:method]
                @tree_base = setting(:tree_base)
                @ldap_user = @ldap_creds.delete :auth
            end
        else
            logger.warn "net/ldap gem not available" if setting(:ldap_creds)
        end

        # Do we want to use exchange web services to manage bookings
        if CAN_OFFICE
            logger.debug "Setting OFFICE"
            @office_organiser_location = setting(:office_organiser_location) 
            @office_client_id = setting(:office_client_id)
            @office_secret = setting(:office_secret)
            @office_scope = setting(:office_scope)
            @office_site = setting(:office_site)
            @office_token_url = setting(:office_token_url)
            @office_options = setting(:office_options)
            @office_user_email = setting(:office_user_email)
            @office_user_password = setting(:office_user_password)
            @office_delegated = setting(:office_delegated)
            @office_room = (setting(:office_room) || system.email)
            # supports: SMTP, PSMTP, SID, UPN (user principle name)
            # NOTE:: Using UPN we might be able to remove the LDAP requirement
            @office_connect_type = (setting(:office_connect_type) || :SMTP).to_sym
            @timezone = setting(:room_timezone)

            @client = ::Microsoft::Office.new({
                client_id: @office_client_id || ENV['OFFICE_CLIENT_ID'],
                client_secret: @office_secret || ENV["OFFICE_CLIENT_SECRET"],
                app_site: @office_site || ENV["OFFICE_SITE"] || "https://login.microsoftonline.com",
                app_token_url: @office_token_url || ENV["OFFICE_TOKEN_URL"],
                app_scope: @office_scope || ENV['OFFICE_SCOPE'] || "https://graph.microsoft.com/.default",
                graph_domain: ENV['GRAPH_DOMAIN'] || "https://graph.microsoft.com",
                service_account_email: @office_user_password || ENV['OFFICE_ACCOUNT_EMAIL'],
                service_account_password: @office_user_password || ENV['OFFICE_ACCOUNT_PASSWORD'],
                internet_proxy: @internet_proxy || ENV['INTERNET_PROXY'],
                delegated: @office_delegated || false
            })
        else
            logger.warn "oauth2 gem not available" if setting(:office_creds)
        end

        # Load the last known values (persisted to the DB)
        self[:waiter_status] = (setting(:waiter_status) || :idle).to_sym
        self[:waiter_call] = self[:waiter_status] != :idle

        self[:catering_status] = setting(:last_catering_status) || {}
        self[:order_status] = :idle

        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)


        # unsubscribe to all swipe IDs if any are subscribed
        if @subs.present?
            @subs.each do |sub|
                unsubscribe(sub)
            end

            @subs = nil
        end

        # Are there any swipe card integrations
        if system.exists? :Security
            readers = setting(:card_readers)
            if readers.present?
                security = system[:Security]

                readers = readers.is_a?(Array) ? readers : [readers]
                sys = system
                @subs = []
                readers.each do |id|
                    @subs << sys.subscribe(:Security, 1, id.to_s) do |notice|
                        if ignore_first_swipe
                            ignore_first_swipe = false
                        else
                            swipe_occured(notice.value)
                        end
                    end
                end
            end
        end

        fetch_bookings
        schedule.clear
        schedule.every(setting(:update_every) || '5m') { fetch_bookings }
    end


    def set_light_status(status)
        lightbar = system[:StatusLight]
        return if lightbar.nil?

        case status.to_sym
        when :unavailable
            lightbar.colour(:red)
        when :available
            lightbar.colour(:green)
        when :pending
            lightbar.colour(:orange)
        else
            lightbar.colour(:off)
        end
    end


    # ======================================
    # Waiter call information
    # ======================================
    def waiter_call(state)
        status = is_affirmative?(state)

        self[:waiter_call] = status

        # Used to highlight the service button
        if status
            self[:waiter_status] = :pending
        else
            self[:waiter_status] = :idle
        end

        define_setting(:waiter_status, self[:waiter_status])
    end

    def call_acknowledged
        self[:waiter_status] = :accepted
        define_setting(:waiter_status, self[:waiter_status])
    end


    # ======================================
    # Catering Management
    # ======================================
    def catering_status(details)
        self[:catering_status] = details

        # We'll turn off the green light on the waiter call button
        if self[:waiter_status] != :idle && details[:progress] == 'visited'
            self[:waiter_call] = false
            self[:waiter_status] = :idle
            define_setting(:waiter_status, self[:waiter_status])
        end

        define_setting(:last_catering_status, details)
    end

    def commit_order(order_details)
        self[:order_status] = :pending
        status = self[:catering_status]

        if status && status[:progress] == 'visited'
            status = status.dup
            status[:progress] = 'cleaned'
            self[:catering_status] = status
        end

        if self[:catering]
            sys = system
            @oid ||= 1
            systems(self[:catering])[:Orders].add_order({
                id: "#{sys.id}_#{@oid}",
                created_at: Time.now.to_i,
                room_id: sys.id,
                room_name: sys.name,
                order: order_details
            })
        end
    end

    def order_accepted
        self[:order_status] = :accepted
    end

    def order_complete
        self[:order_status] = :idle
    end



    # ======================================
    # ROOM BOOKINGS:
    # ======================================
    def fetch_bookings(*args)
        # Make the request
        response = @client.get_bookings_by_user(user_id: @office_room, start_param: Time.now.midnight, end_param: Time.now.tomorrow.midnight)

        task {
            todays_bookings(response, @office_organiser_location)
        }.then(proc { |bookings|
            self[:today] = bookings
        }, proc { |e| logger.print_error(e, 'error fetching bookings') })
    end


    # ======================================
    # Meeting Helper Functions
    # ======================================

    def start_meeting(meeting_ref)
        self[:last_meeting_started] = meeting_ref
        self[:meeting_pending] = meeting_ref
        self[:meeting_ending] = false
        self[:meeting_pending_notice] = false
        define_setting(:last_meeting_started, meeting_ref)
    end

    def cancel_meeting(start_time)
        task {
            delete_ews_booking (start_time / 1000).to_i
        }.then(proc { |count|
            logger.debug { "successfully removed #{count} bookings" }

            self[:last_meeting_started] = start_time
            self[:meeting_pending] = start_time
            self[:meeting_ending] = false
            self[:meeting_pending_notice] = false
        }, proc { |error|
            logger.print_error error, 'removing ews booking'
        })
    end

    # If last meeting started !== meeting pending then
    #  we'll show a warning on the in room touch panel
    def set_meeting_pending(meeting_ref)
        self[:meeting_ending] = false
        self[:meeting_pending] = meeting_ref
        self[:meeting_pending_notice] = true
    end

    # Meeting ending warning indicator
    # (When meeting_ending !== last_meeting_started then the warning hasn't been cleared)
    # The warning is only displayed when meeting_ending === true
    def set_end_meeting_warning(meeting_ref = nil, extendable = false)
        if self[:last_meeting_started].nil? || self[:meeting_ending] != (meeting_ref || self[:last_meeting_started])
            self[:meeting_ending] = true

            # Allows meeting ending warnings in all rooms
            self[:last_meeting_started] = meeting_ref if meeting_ref
            self[:meeting_canbe_extended] = extendable
        end
    end

    def clear_end_meeting_warning
        self[:meeting_ending] = self[:last_meeting_started]
    end
    # ---------

    def create_meeting(options)
        # Check that the required params exist
        required_fields = ["start", "end"]
        check = required_fields - options.keys
        if check != []
            # There are missing required fields
            logger.info "Required fields missing: #{check}"
            raise "missing required fields: #{check}"
        end

        logger.debug "Passed Room options: --------------------"
        logger.debug options
        logger.debug options.to_json

        req_params = {}
        req_params[:room_email] = @ews_room
        req_params[:organizer] = options[:user_email]
        req_params[:subject] = options[:title]
        req_params[:start_time] = Time.at(options[:start].to_i / 1000).utc.to_i
        req_params[:end_time] = Time.at(options[:end].to_i / 1000).utc.to_i

       
        # TODO:: Catch error for booking failure
        begin
            id = make_office_booking req_params
        rescue Exception => e
            logger.debug e.message
            logger.debug e.backtrace.inspect
            raise e
        end

        
        logger.debug { "successfully created booking: #{id}" }
        "Ok"
    end


    protected


    def swipe_occured(info)
        # Update the user details
        @last_swipe_at = Time.now.to_i
        self[:fullname] = "#{info[:firstname]} #{info[:lastname]}"
        self[:username] = info[:staff_id]
        email = nil

        if self[:username] && @ldap_creds
            email = EMAIL_CACHE[self[:username]]
            if email
                set_email(email)
                logger.debug { "email #{email} found in cache" }
            else
                # Cache username here as self[:username] might change while we
                #  looking up the previous username
                username = self[:username]

                logger.debug { "looking up email for #{username} - #{self[:fullname]}" }
                task {
                    ldap_lookup_email username
                }.then do |email|
                    if email
                        logger.debug { "email #{email} found in LDAP" }
                        EMAIL_CACHE[username] = email
                        set_email(email)
                    else
                        logger.warn "no email found in LDAP for #{username}"
                        set_email nil
                    end
                end
            end
        else
            logger.warn "no staff ID for user #{self[:fullname]}"
            set_email nil
        end
    end

    def set_email(email)
        self[:email] = email
        self[:swiped] += 1
    end

    # ====================================
    # LDAP lookup to occur in worker thread
    # ====================================
    def ldap_lookup_email(username)
        email = EMAIL_CACHE[username]
        return email if email

        ldap = Net::LDAP.new @ldap_creds
        ldap.authenticate @ldap_user[:username], @ldap_user[:password] if @ldap_user

        login_filter = Net::LDAP::Filter.eq('sAMAccountName', username)
        object_filter = Net::LDAP::Filter.eq('objectClass', '*')
        treebase = @tree_base
        search_attributes = ['mail']

        email = nil
        ldap.bind
        ldap.search({
            base: treebase,
            filter: object_filter & login_filter,
            attributes: search_attributes
        }) do |entry|
            email = get_attr(entry, 'mail')
        end

        # Returns email as a promise
        EMAIL_CACHE[username] = email
        email
    end

    def get_attr(entry, attr_name)
        if attr_name != "" && attr_name != nil
            entry[attr_name].is_a?(Array) ? entry[attr_name].first : entry[attr_name]
        end
    end
    # ====================================


    # =======================================
    # EWS Requests to occur in a worker thread
    # =======================================
    def make_office_booking(user_email: nil, subject: 'On the spot booking', room_email:, start_time:, end_time:, organizer:)

        booking_data = {
            subject: subject,
            start: { dateTime: start_time, timeZone: "UTC" },
            end: { dateTime: end_time, timeZone: "UTC" },
            location: { displayName: @office_room, locationEmailAddress: @office_room },
            attendees: [ emailAddress: { address: organizer, name: "User"}]
        }.to_json

        logger.debug "Creating booking:"
        logger.debug booking_data

        # client = OAuth2::Client.new(@office_client_id, @office_secret, {site: @office_site, token_url: @office_token_url})

        # begin
        #     access_token = client.client_credentials.get_token({
        #         :scope => @office_scope
        #         # :client_secret => ENV["OFFICE_APP_CLIENT_SECRET"],
        #         # :client_id => ENV["OFFICE_APP_CLIENT_ID"]
        #     }).token
        # rescue Exception => e
        #     logger.debug e.message
        #     logger.debug e.backtrace.inspect
        #     raise e
        # end


        # # Set out domain, endpoint and content type
        # domain = 'https://graph.microsoft.com'
        # host = 'graph.microsoft.com'
        # endpoint = "/v1.0/users/#{@office_room}/events"
        # content_type = 'application/json;odata.metadata=minimal;odata.streaming=true'

        # # Create the request URI and config
        # office_api = UV::HttpEndpoint.new(domain, tls_options: {host_name: host})
        # headers = {
        #     'Authorization' => "Bearer #{access_token}",
        #     'Content-Type' => content_type
        # }

        # Make the request

        # response = office_api.post(path: "#{domain}#{endpoint}", body: booking_data, headers: headers).value
        response = @client.create_booking(room_id: system.id, start_param: start_time, end_param: end_time, subject: subject, current_user: {email: organizer, name: "User"})
        logger.debug response.body
        logger.debug response.to_json
        logger.debug response['id']

        id = response['id']

        # Return the booking IDs
        id
    end

    def delete_ews_booking(delete_at)
        now = Time.now
        if @timezone
            start  = now.in_time_zone(@timezone).midnight
            ending = now.in_time_zone(@timezone).tomorrow.midnight
        else
            start  = now.midnight
            ending = now.tomorrow.midnight
        end

        count = 0

        cli = Viewpoint::EWSClient.new(*@ews_creds)

        if @use_act_as
            # TODO:: think this line can be removed??
            delete_at = Time.parse(delete_at.to_s).to_i

            opts = {}
            opts[:act_as] = @ews_room if @ews_room

            folder = cli.get_folder(:calendar, opts)
            items = folder.items({:calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
            items = cli.find_items({:folder_id => :calendar, :calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        end

        items.each do |meeting|
            meeting_time = Time.parse(meeting.ews_item[:start][:text])

            # Remove any meetings that match the start time provided
            if meeting_time.to_i == delete_at
                meeting.delete!(:recycle, send_meeting_cancellations: 'SendOnlyToAll')
                count += 1
            end
        end

        # Return the number of meetings removed
        count
    end

    def todays_bookings(response, office_organiser_location)
        results = []
        response.each{|booking| 
            # start_time = Time.parse(booking['start']['dateTime']).utc.iso8601[0..18] + 'Z'
            # end_time = Time.parse(booking['end']['dateTime']).utc.iso8601[0..18] + 'Z'
            start_time = ActiveSupport::TimeZone.new('UTC').parse(booking['start']['dateTime']).iso8601
            end_time = ActiveSupport::TimeZone.new('UTC').parse(booking['end']['dateTime']).iso8601

            if office_organiser_location == 'attendees'
                # Grab the first attendee
                organizer = booking['attendees'][0]['emailAddress']['name']
            else
                # Grab the organiser
                organizer = booking['organizer']['emailAddress']['name']
            end

            results.push({
                :Start => start_time,
                :End => end_time,
                :Subject => booking['subject'],
                :owner => organizer
            })
        }

        results
    end
    # =======================================
end
