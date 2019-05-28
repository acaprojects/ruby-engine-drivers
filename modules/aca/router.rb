# frozen_string_literal: true

require 'algorithms'
require 'set'

module Aca; end

class Aca::Router
    include ::Orchestrator::Constants

    descriptive_name 'ACA Signal Router'
    generic_name :Router
    implements :logic
    description <<~DESC
        Signal distribution management for handling routing across multiple
        devices and complex/layered switching infrastructure.
    DESC


    default_settings(
        # Nested hash of signal connectivity. See SignalGraph.from_map.
        connections: {}
    )


    # ------------------------------
    # Callbacks

    def on_load
        on_update
    end

    def on_update
        connections = setting :connections

        logger.warn 'no connections defined' unless connections

        load_from_map(connections || {})
    end


    # ------------------------------
    # Public API

    # Route a set of signals to arbitrary destinations.
    #
    # `signal_map`  is a hash of the structure `{ source: sink | [sinks] }`
    # 'atomic'      may be used to prevent activation of any part of the signal
    #               map, prior to any device interaction taking place, if any
    #               of the routes are not possible
    # `force`       control if switch events should be forced, even when the
    #               associated device module is already reporting it's on the
    #               correct input
    #
    # Multiple sources can be specified simultaneously, or if connecting a
    # single source to a single destination, Ruby's implicit hash syntax can be
    # used to let you express it neatly as `connect source => sink`.
    #
    # A promise is returned that will resolve when all device interactions have
    # completed. This will be fullfilled with the applied signal map and a
    # boolean - true if this was a complete recall, or false if partial.
    def connect(signal_map, atomic: false, force: false)
        # Convert the signal map to a nested hash of routes
        # { source => { dest => [edges] } }
        edge_map = build_edge_map signal_map, atomic: atomic

        # Reduce the edge map to a set of edges
        edges_to_connect = edge_map.reduce(Set.new) do |s, (_, routes)|
            s | routes.values.flatten
        end

        switch = activate_all edges_to_connect, atomic: atomic, force: force

        switch.then do |success, failed|
            if failed.empty?
                logger.debug 'signal map activated'
                recalled_map = edge_map.transform_values(&:keys)
                [recalled_map, true]

            elsif success.empty?
                thread.reject 'failed to activate, devices untouched'

            else
                logger.warn 'signal map partially activated'
                recalled_map = edge_map.transform_values do |routes|
                    routes.each_with_object([]) do |(output, edges), completed|
                        completed << output if success.superset? Set.new(edges)
                    end
                end
                [recalled_map, false]
            end
        end
    end

    # Lookup the input on a sink node that would be used to connect a specific
    # source to it.
    #
    # `on` may be ommited if the source node has only one neighbour (e.g. is
    # an input node) and you wish to query the phsycial input associated with
    # it. Similarly `on` maybe used to look up the input used by any other node
    # within the graph that would be used to show `source`.
    def input_for(source, on: nil)
        if on.nil?
            edges = signal_graph.incoming_edges source
            raise "no outputs from #{source}" if edges.empty?
            raise "multiple outputs from #{source}, please specify a sink" \
                unless edges.map(&:device).uniq.size == 1
        else
            _, edges = route source, on
        end

        edges.last.input
    end

    # Find the device that input node is attached to.
    #
    # Efficiently queries the graph for the device that an signal input connects
    # to for checking signal properties revealed by the device state.
    def device_for(source)
        edges = signal_graph.incoming_edges source
        raise "no outputs from #{source}" if edges.empty?
        raise "#{source} is not an input node" if edges.size > 1
        edges.first.device
    end

    # Get a list of devices that a signal passes through for a specific route.
    #
    # This may be used to walk up or down a path to find encoders, decoders or
    # other devices that may provide some interesting state, or require
    # additional interactions (signal presence monitoring etc).
    def devices_between(source, sink)
        _, edges = route source, sink
        edges.map(&:device)
    end

    # Given a sink id, find the chain of devices that sit immediately upstream
    # in the signal path. The returned list will include all devices which for
    # a static, linear chain exists before any routing is possible
    #
    # This may be used to find devices that are installed for the use of this
    # output only (decoders, image processors etc).
    #
    # If the sink itself has mutiple inputs, the input to retrieve the chain for
    # may be specified with the `on_input` param.
    def upstream_devices_of(sink, on_input: nil)
        device_chain = []

        # Bail out early if there's no linear signal path from the sink
        return device_chain unless on_input || signal_graph.outdegree(sink) == 1

        # Otherwise, grab the initial edge from the sink node
        initial = signal_graph[sink].edges.values.find do |edge|
            if on_input
                edge.input == on_input.to_sym
            else
                true
            end
        end

        # Then walk the graph and accumulate devices until we reach a branch
        successors = [initial.target]
        while successors.size == 1
            node = successors.first
            device_chain << node
            successors = signal_graph.successors node
        end

        device_chain
    end

    # Check if a source can be routed to a specific sink.
    def path_exists_between?(source, sink)
        paths[sink].distance_to[source].finite?
    end


    # ------------------------------
    # Internals

    protected

    def signal_graph
        @signal_graph ||= SignalGraph.new
    end

    def paths
        @path_cache ||= Hash.new do |hash, node|
            hash[node] = signal_graph.dijkstra node
        end
    end

    def load_from_map(connections)
        logger.debug 'building graph from signal map'

        @path_cache = nil
        @signal_graph = SignalGraph.from_map(connections).freeze

        # TODO: track active signal source at each node and expose as a hash
        self[:nodes] = signal_graph.node_ids
        self[:inputs] = signal_graph.sinks
        self[:outputs] = signal_graph.sources
    end

    # Find the shortest path between between two nodes and return a list of the
    # nodes which this passes through and their connecting edges.
    def route(source, sink)
        source = source.to_sym
        sink = sink.to_sym

        path = paths[sink]

        distance = path.distance_to[source]
        raise "no route from #{source} to #{sink}" if distance.infinite?

        logger.debug do
            "found route connecting #{source} to #{sink} in #{distance} hops"
        end

        nodes = []
        edges = []
        node = source
        until node.nil?
            nodes.unshift node
            prev = path.predecessor[node]
            edges << signal_graph[prev].edges[node] unless prev.nil?
            node = prev
        end

        logger.debug { edges.map(&:to_s).join ' then ' }

        [nodes, edges]
    end

    # Convert a signal map of the structure
    #
    #     source => [dest]
    #
    # to a nested hash of the structure
    #
    #     source => { dest => [edges] }
    #
    def build_edge_map(signal_map, atomic: false)
        nodes_in_use = Set.new
        edge_map = {}

        signal_map.each_pair do |source, sinks|
            source = source.to_sym
            sinks = Array(sinks).map(&:to_sym)

            source_nodes = Set.new
            edge_map[source] = {}

            sinks.each do |sink|
                begin
                    nodes, edges = route source, sink

                    if nodes_in_use.intersect? Set[nodes]
                        partial_map = edge_map.transform_values(&:keys)
                        route = "route from #{source} to #{sink}"
                        raise "#{route} conflicts with routes in #{partial_map}"
                    end

                    source_nodes |= nodes
                    edge_map[source][sink] = edges
                rescue => e
                    # note `route` may also throw an exception (e.g. when there
                    # is an invalid source / sink or unroutable path)
                    raise if atomic
                    logger.error e.message
                end
            end

            nodes_in_use |= source_nodes
        end

        edge_map
    end

    # Given a set of edges, activate them all and return a promise that will
    # resolve following the completion of all device interactions.
    #
    # The returned promise contains the original edges, partitioned into
    # success and failure sets.
    def activate_all(edges, atomic: false, force: false)
        success = Set.new
        failed = Set.new

        # Filter out any edges we can skip over
        skippable = edges.reject { |e| needs_activation? e, force: force }
        success  |= skippable
        edges    -= skippable

        # Remove anything that we know will fail up front
        unroutable = edges.reject { |e| can_activate? e }
        failed    |= unroutable
        edges     -= unroutable

        raise 'can not perform all routes' if atomic && unroutable.any?

        interactions = edges.map { |e| activate e }

        thread.finally(interactions).then do |results|
            edges.zip(results).each do |edge, (result, resolved)|
                if resolved
                    success << edge
                else
                    logger.warn "failed to switch #{edge}: #{result}"
                    failed << edge
                end
            end
            [success, failed]
        end
    end

    def needs_activation?(edge, force: false)
        mod = system[edge.device]

        fail_with = proc do |reason|
            logger.info "module for #{edge.device} #{reason} - skipping #{edge}"
            return false
        end

        single_source = signal_graph.outdegree(edge.source) == 1

        fail_with['does not exist, but appears to be an alias'] \
            if mod.nil? && single_source

        fail_with['already on correct input'] \
            if edge.nx1? && mod && mod[:input] == edge.input && !force

        fail_with['has an incompatible api, but only a single input defined'] \
            if edge.nx1? && !mod.respond_to?(:switch_to) && single_source

        true
    end

    def can_activate?(edge)
        mod = system[edge.device]

        fail_with = proc do |reason|
            logger.warn "mod #{edge.device} #{reason} - can not switch #{edge}"
            return false
        end

        fail_with['does not exist'] if mod.nil?

        fail_with['offline'] if mod[:connected] == false

        fail_with['has an incompatible api (missing #switch_to)'] \
            if edge.nx1? && !mod.respond_to?(:switch_to)

        fail_with['has an incompatible api (missing #switch)'] \
            if edge.nxn? && !mod.respond_to?(:switch)

        true
    end

    def activate(edge)
        mod = system[edge.device]

        if edge.nx1?
            mod.switch_to edge.input
        elsif edge.nxn?
            mod.switch edge.input => edge.output
        else
            raise 'unexpected edge type'
        end
    end
end

# Graph data structure for respresentating abstract signal networks.
#
# All signal sinks and sources are represented as nodes, with directed edges
# holding connectivity information needed to execute device level interaction
# to 'activate' the edge.
#
# Directivity of the graph is inverted from the signal flow - edges use signal
# sinks as source and signal sources as their terminus. This optimises for
# cheap removal of signal sinks and better path finding (as most environments
# will have a small number of displays and a large number of sources).
class Aca::Router::SignalGraph
    Paths = Struct.new :distance_to, :predecessor

    class Edge
        attr_reader :source, :target, :device, :input, :output

        Meta = Struct.new(:device, :input, :output)

        def initialize(source, target, &blk)
            @source = source.to_sym
            @target = target.to_sym

            meta = Meta.new.tap(&blk)
            normalise_io = lambda do |x|
                if x.is_a? String
                    x[/^\d+$/]&.to_i || x.to_sym
                else
                    x
                end
            end
            @device = meta.device&.to_sym
            @input  = normalise_io[meta.input]
            @output = normalise_io[meta.output]
        end

        def to_s
            "#{target} to #{device} (in #{input})"
        end

        # Check if the edge is a switchable input on a single output device
        def nx1?
            output.nil?
        end

        # Check if the edge a matrix switcher / multi-output device
        def nxn?
            !nx1?
        end
    end

    class Node
        attr_reader :id, :edges

        def initialize(id)
            @id = id.to_sym
            @edges = Hash.new do |_, other_id|
                raise ArgumentError, "No edge from \"#{@id}\" to \"#{other_id}\""
            end
        end

        def join(other_id, datum)
            edges[other_id.to_sym] = datum
            self
        end

        def to_s
            id.to_s
        end

        def eql?(other)
            id == other
        end

        def hash
            id.hash
        end
    end

    include Enumerable

    attr_reader :nodes

    def initialize
        @nodes = Hash.new do |_, id|
            raise ArgumentError, "\"#{id}\" does not exist"
        end
    end

    def [](id)
        id = id.to_sym
        nodes[id]
    end

    def insert(id)
        id = id.to_sym
        nodes[id] = Node.new id unless nodes.include? id
        self
    end

    alias << insert

    # If there is *certainty* the node has no incoming edges (i.e. it was a temp
    # node used during graph construction), `check_incoming_edges` can be set
    # to false to keep this O(1) rather than O(n). Using this flag at any other
    # time will result a corrupt structure.
    def delete(id, check_incoming_edges: true)
        id = id.to_sym
        nodes.delete(id) { raise ArgumentError, "\"#{id}\" does not exist" }
        each { |node| node.edges.delete id } if check_incoming_edges
        self
    end

    def join(source, target, &block)
        source = source.to_sym
        target = target.to_sym
        datum = Edge.new(source, target, &block)
        nodes[source].join target, datum
        self
    end

    def each(&block)
        nodes.values.each(&block)
    end

    def include?(id)
        id = id.to_sym
        nodes.key? id
    end

    def node_ids
        map(&:id)
    end

    def successors(id)
        id = id.to_sym
        nodes[id].edges.keys
    end

    def sources
        node_ids.select { |id| indegree(id).zero? }
    end

    def sinks
        node_ids.select { |id| outdegree(id).zero? }
    end

    def incoming_edges(id)
        id = id.to_sym
        each_with_object([]) do |node, edges|
            edges << node.edges[id] if node.edges.key? id
        end
    end

    def outgoing_edges(id)
        id = id.to_sym
        nodes[id].edges.values
    end

    def indegree(id)
        incoming_edges(id).size
    end

    def outdegree(id)
        id = id.to_sym
        nodes[id].edges.size
    end

    def dijkstra(id)
        id = id.to_sym

        active = Containers::PriorityQueue.new { |x, y| (x <=> y) == -1 }
        distance_to = Hash.new { 1.0 / 0.0 }
        predecessor = {}

        distance_to[id] = 0
        active.push id, distance_to[id]

        until active.empty?
            u = active.pop
            successors(u).each do |v|
                alt = distance_to[u] + 1
                next unless alt < distance_to[v]
                distance_to[v] = alt
                predecessor[v] = u
                active.push v, distance_to[v]
            end
        end

        Paths.new distance_to, predecessor
    end

    def inspect
        object_identifier = "#{self.class.name}:0x#{format('%02x', object_id)}"
        nodes = map(&:inspect).join ', '
        "#<#{object_identifier} @nodes={ #{nodes} }>"
    end

    def to_s
        "{ #{to_a.join ', '} }"
    end

    # Pre-parse a connection map into a normalised nested hash structure
    # suitable for parsing into the graph.
    #
    # This assumes the input map has been parsed from JSON so takes care of
    # mapping keys back to integers (where suitable) and expanding sources
    # specified as an array into a nested Hash. The target normalised output is
    #
    #     { device: { input: source } }
    #
    def self.normalise(map)
        map.transform_values do |inputs|
            case inputs
            when Array
                (1..inputs.size).zip(inputs).to_h
            when Hash
                inputs.transform_keys do |key|
                    key.to_s[/^\d+$/]&.to_i || key.to_sym
                end
            else
                raise ArgumentError, 'inputs must be a Hash or Array'
            end
        end
    end

    # Extract module references from a connection map.
    #
    # This is a destructive operation that will tranform outputs specified as
    # `device as output` to simply `output` and return a Hash of the structure
    # `{ output: device }`.
    def self.extract_mods!(map)
        mods = HashWithIndifferentAccess.new

        map.transform_keys! do |key|
            mod, node = key.to_s.split(' as ')
            node ||= mod
            mods[node] = mod
            node.to_sym
        end

        mods
    end

    # Build a signal map from a nested hash of input connectivity. The input
    # map should be of the structure
    #
    #     { device: { input_name: source } }
    #   or
    #     { device: [source] }
    #
    # When inputs are specified as an array, 1-based indices will be used.
    #
    # Sources that refer to the output of a matrix switcher are defined as
    # "device__output" (using two underscores to seperate the output
    # name/number and device).
    #
    # For example, a map containing two displays and 2 laptop inputs, all
    # connected via 2x2 matrix switcher would be:
    #     {
    #         Display_1: {
    #             hdmi: :Switcher_1__1
    #         },
    #         Display_2: {
    #             hdmi: :Switcher_1__2
    #         },
    #         Switcher_1: [:Laptop_1, :Laptop_2],
    #     }
    #
    # Device keys should relate to module id's for control. These may also be
    # aliased by defining them as as "mod as device". This can be used to
    # provide better readability (e.g. "Display_1 as Left_LCD") or to segment
    # them so that only specific routes are allowed. This approach enables
    # devices such as centralised matrix switchers split into multiple virtual
    # switchers that only have access to a subset of the inputs.
    def self.from_map(map)
        graph = new

        matrix_nodes = []

        connections = normalise map

        mods = extract_mods! connections

        connections.each_pair do |device, inputs|
            # Create the node for the signal sink
            graph << device

            inputs.each_pair do |input, source|
                # Create a node and edge to each input source
                graph << source
                graph.join(device, source) do |edge|
                    edge.device = mods[device]
                    edge.input  = input
                end

                # Check is the input is a matrix switcher or multi-output
                # device (such as a USB switch).
                upstream_device, output = source.to_s.split '__'
                next if output.nil?

                upstream_device = upstream_device.to_sym
                matrix_nodes |= [upstream_device]

                # Push in nodes and edges to each matrix input
                matrix_inputs = connections[upstream_device]
                matrix_inputs.each_pair do |matrix_input, upstream_source|
                    graph << upstream_source
                    graph.join(source, upstream_source) do |edge|
                        edge.device = mods[upstream_device]
                        edge.input  = matrix_input
                        edge.output = output
                    end
                end
            end
        end

        # Remove any temp 'matrix device nodes' as we now how fully connected
        # nodes for each input and output.
        matrix_nodes.each { |id| graph.delete id, check_incoming_edges: false }

        graph
    end
end
