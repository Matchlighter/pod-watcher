require "http/server"
require "json"
require "log"
require "mutex"
require "kubernetes"

# Pod Watcher Microservice
# Watches Kubernetes pods and maintains a mapping of Pod IPs to metadata.
# Provides a REST API to query pod information by IP address.

Log.setup(:info)

# Pod metadata structure
struct PodMetadata
  include JSON::Serializable

  property name : String
  property namespace : String
  property uid : String
  property labels : Hash(String, String)
  property annotations : Hash(String, String)
  property node_name : String?
  property phase : String
  property pod_ip : String?
  property host_ip : String?
  property start_time : String?
  property conditions : Array(PodCondition)
  property containers : Array(ContainerInfo)

  def initialize(@name, @namespace, @uid, @labels, @annotations, @node_name, 
                 @phase, @pod_ip, @host_ip, @start_time, @conditions, @containers)
  end
end

struct PodCondition
  include JSON::Serializable

  property type : String
  property status : String
  property reason : String?
  property message : String?

  def initialize(@type, @status, @reason = nil, @message = nil)
  end
end

struct ContainerInfo
  include JSON::Serializable

  property name : String
  property image : String
  property ports : Array(PortInfo)

  def initialize(@name, @image, @ports = [] of PortInfo)
  end
end

struct PortInfo
  include JSON::Serializable

  property containerPort : Int32
  property protocol : String

  def initialize(@containerPort, @protocol)
  end
end

class PodWatcher
  @pod_map = Hash(String, PodMetadata).new
  @mutex = Mutex.new
  @k8s : Kubernetes::Client

  def initialize
    @k8s = Kubernetes::Client.new
    Log.info { "Loaded Kubernetes configuration" }
  end

  def extract_pod_metadata(pod : Kubernetes::Pod) : PodMetadata?
    pod_ip = pod.status["podIP"]?.try(&.as_s)
    return nil unless pod_ip

    labels = pod.metadata.labels || {} of String => String
    annotations = pod.metadata.annotations || {} of String => String

    conditions = [] of PodCondition
    if pod_conditions = pod.status["conditions"]?
      pod_conditions.as_a.each do |cond|
        conditions << PodCondition.new(
          cond["type"].as_s,
          cond["status"].as_s,
          cond["reason"]?.try(&.as_s),
          cond["message"]?.try(&.as_s)
        )
      end
    end

    containers = [] of ContainerInfo
    pod.spec.containers.each do |cont|
      ports = [] of PortInfo
      cont.ports.each do |port|
        if cp = port.container_port
          ports << PortInfo.new(
            cp,
            port.protocol || "TCP"
          )
        end
      end
      containers << ContainerInfo.new(
        cont.name,
        cont.image,
        ports
      )
    end

    PodMetadata.new(
      name: pod.metadata.name,
      namespace: pod.metadata.namespace,
      uid: pod.metadata.uid.to_s,
      labels: labels,
      annotations: annotations,
      node_name: pod.spec.node_name.presence,
      phase: pod.status["phase"]?.try(&.as_s) || "Unknown",
      pod_ip: pod_ip,
      host_ip: pod.status["hostIP"]?.try(&.as_s),
      start_time: pod.status["startTime"]?.try(&.as_s),
      conditions: conditions,
      containers: containers
    )
  end

  def watch_pods
    Log.info { "Starting pod watcher..." }

    # Initial listing to populate the map
    initial_list
    
    # Watch for changes
    spawn do
      loop do
        watch_for_changes
      rescue ex
        Log.error { "Error in pod watcher: #{ex.message}" }
        Log.error { ex.inspect_with_backtrace }
        Log.info { "Restarting watch stream in 5 seconds..." }
        sleep 5.seconds
      end
    end
  end

  def initial_list
    Log.info { "Fetching initial pod list from all namespaces..." }
    
    # List all pods - jgaskins/kubernetes returns Array(Kubernetes::Pod)
    pods = @k8s.pods
    
    pods.each do |pod|
      if metadata = extract_pod_metadata(pod)
        if ip = metadata.pod_ip
          @mutex.synchronize do
            @pod_map[ip] = metadata
          end
        end
      end
    end
    
    Log.info { "Initial pod map populated with #{@pod_map.size} pods" }
  rescue ex
    Log.error { "Error during initial pod listing: #{ex.message}" }
    Log.error { ex.inspect_with_backtrace }
  end

  def watch_for_changes
    Log.info { "Starting watch for pod changes..." }
    
    # Watch all pods - watch_pods takes a block with Kubernetes::Watch
    @k8s.watch_pods do |watch|
      pod = watch.object
      
      metadata = extract_pod_metadata(pod)
      next unless metadata
      
      pod_ip = metadata.pod_ip
      next unless pod_ip

      @mutex.synchronize do
        case watch
        when .added?, .modified?
          @pod_map[pod_ip] = metadata
          Log.info { "Updated pod map for IP #{pod_ip}: #{metadata.namespace}/#{metadata.name}" }
        when .deleted?
          if @pod_map.has_key?(pod_ip)
            @pod_map.delete(pod_ip)
            Log.info { "Removed pod from map: IP #{pod_ip}" }
          end
        end
      end
    end
  end

  def get_pod_by_ip(ip : String) : PodMetadata?
    @mutex.synchronize do
      @pod_map[ip]?
    end
  end

  def get_all_pods(namespace : String? = nil) : Hash(String, PodMetadata)
    @mutex.synchronize do
      if ns = namespace
        @pod_map.select { |_, metadata| metadata.namespace == ns }
      else
        @pod_map.dup
      end
    end
  end

  def pod_count : Int32
    @mutex.synchronize do
      @pod_map.size
    end
  end
end

# Create global pod watcher instance
pod_watcher = PodWatcher.new
pod_watcher.watch_pods

# HTTP Server
port = ENV.fetch("PORT", "8080").to_i
host = ENV.fetch("HOST", "0.0.0.0")

server = HTTP::Server.new do |context|
  case {context.request.method, context.request.path}
  when {"GET", "/health"}
    context.response.content_type = "application/json"
    context.response.status_code = 200
    context.response.print({"status" => "healthy", "pod_count" => pod_watcher.pod_count}.to_json)

  when {"GET", "/ready"}
    context.response.content_type = "application/json"
    if pod_watcher.pod_count > 0
      context.response.status_code = 200
      context.response.print({"status" => "ready", "pod_count" => pod_watcher.pod_count}.to_json)
    else
      context.response.status_code = 503
      context.response.print({"status" => "not ready", "pod_count" => 0}.to_json)
    end

  when {"GET", "/pod"}
    ip = context.request.query_params["ip"]?
    
    if ip.nil?
      context.response.content_type = "application/json"
      context.response.status_code = 400
      context.response.print({"error" => "IP parameter is required"}.to_json)
    elsif metadata = pod_watcher.get_pod_by_ip(ip)
      context.response.content_type = "application/json"
      context.response.status_code = 200
      context.response.print(metadata.to_json)
    else
      context.response.content_type = "application/json"
      context.response.status_code = 404
      context.response.print({"error" => "No pod found with IP #{ip}"}.to_json)
    end

  when {"GET", "/pods"}
    namespace = context.request.query_params["namespace"]?
    pods = pod_watcher.get_all_pods(namespace)
    
    context.response.content_type = "application/json"
    context.response.status_code = 200
    context.response.print({"pods" => pods, "count" => pods.size}.to_json)

  else
    context.response.status_code = 404
    context.response.print("Not Found")
  end
end

address = server.bind_tcp host, port
Log.info { "Pod Watcher Microservice starting on #{address}" }
server.listen
