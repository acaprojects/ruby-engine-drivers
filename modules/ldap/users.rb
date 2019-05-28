require 'net/ldap'

module LDAP; end
class LDAP::Users
    include ::Orchestrator::Constants

    descriptive_name 'LDAP User Listings'
    generic_name :Users
    implements :logic

    # For encrypted auth use port: 636
    # using auth_method: simple_tls
    default_settings({
        username: "cn=read-only-admin,dc=example,dc=com",
        password: "password",
        host: "ldap.forumsys.com",
        port: 389,
        auth_method: "simple",
        encryption: nil,
        tree_base: "dc=example,dc=com",
        attributes: ['dn', 'givenName', 'sN', 'mail', 'memberOf', 'telephoneNumber'],

        # Fields that should be searchable
        query: ['sN', 'givenName'],

        # Every day at 3am
        fetch_every: "0 3 * * *"
    })

    def on_load
        on_update
    end

    def on_update
        @username = setting(:username)
        @password = setting(:password)
        @host = setting(:host)
        @port = setting(:port)
        @auth_method = (setting(:auth_method) || :simple).to_sym
        @encryption = setting(:encryption)
        @tree_base = setting(:tree_base)
        @attributes = setting(:attributes)

        @users ||= {}
        @query = Array(setting(:query)).map { |attr| attr.to_s.downcase.to_sym }
        @query.each { |attr| @users[attr] ||= [] }

        schedule.clear
        cron = setting(:fetch_every)
        if cron
            schedule.cron(cron) { fetch_user_list }

            # Fetch the list of users of not otherwise known
            schedule.in('30s') { fetch_user_list } if self[:user_count].nil?
        end
    end

    def find_user(query)
        results = []
        @query.each do |attr|
            array = @users[attr]
            # binary search returning the index of the element
            i = (0...array.size).bsearch { |i| array[i][attr].start_with?(query) }
            next unless i

            # Run backwards looking for earlier matches
            loop do
                i -= 1
                element = array[i]
                if element && element[attr].start_with?(query)
                else
                    break
                end
            end

            # Add up to 20 matching results
            count = 0
            loop do
                i += 1
                element = array[i]
                if element && element[attr].start_with?(query)
                    results << element
                else
                    break
                end

                count += 1
                break if count > 20
            end
        end

        # Sort the results
        attr = @query[0]
        results.uniq.sort { |a, b| a[attr] <=> b[attr] }
    end

    # 400_000 users equates to about 200MB of data
    def fetch_user_list
        return if @fetching
        self[:fetching] = true

        users ||= {}
        @query.each { |attr| users[attr] = [] }

        results = task do
            opts = {
              force_no_page: true,
              host: @host,
              port: @port,
              auth: {
                  method: @auth_method,
                  username: @username,
                  password: @password
              }
            }

            if @encryption
                opts[:encryption] = {
                    method: @encryption.to_sym,
                    tls_options: {
                        verify_mode: OpenSSL::SSL::VERIFY_NONE
                    }
                }
            end

            ldap_con = Net::LDAP.new(opts)
            op_filter = Net::LDAP::Filter.eq("objectClass", "person")
            ldap_con.search({
                base: @tree_base,
                filter: op_filter,
                attributes: @attributes,
                # Improve memory usage
                return_result: false
            }) do |entry|
                logger.debug { "processing #{entry.inspect}" }

                # Grab the raw data
                hash = entry.instance_variable_get(:@myhash)

                # Build a nice version of data
                user = {}
                hash.each do |key, value|
                  if value.is_a?(Array) && value.size == 1
                    user[key] = value[0]
                  else
                    user[key] = value
                  end
                end

                # Insert the user in a sorted array for lookup later
                @query.each do |attr|
                    next unless user[attr]
                    user[attr] = user[attr].downcase
                    insort(attr, users[attr], user)
                end
            end

            nil
        end

        # Wait for the users to be fetched
        results.value

        @users = users
        self[:user_count] = users[@query[0]].size
    ensure
        self[:fetching] = false
    end

    private

    def insort(attr, array, item, lo = 0, hi = array.size)
        index = bisect_right(attr, array, item, lo, hi)
        array.insert(index, item)
    end

    def bisect_right(attr, array, item, lo = 0, hi = array.size)
        raise ArgumentError, "lo must be non-negative" if lo < 0

        while lo < hi
            mid = (lo + hi) / 2
            if item[attr] < array[mid][attr]
                hi = mid
            else
                lo = mid + 1
            end
        end

        lo
    end
end
