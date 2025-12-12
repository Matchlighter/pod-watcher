require "http/server"
require "json"
require "log"
require "mutex"
require "kubernetes"
require "netmask"

# Pod Watcher Microservice
# Watches Kubernetes pods and maintains a mapping of Pod IPs to metadata.
# Provides a REST API to query pod information by IP address.

Log.setup_from_env

class PodWatcher
  @pod_map = Hash(String, Kubernetes::Pod::Metadata).new
  @mutex = Mutex.new
  @k8s : Kubernetes::Client

  def initialize
    @k8s = Kubernetes::Client.new
    @cluster_cidr = Netmask.new(ENV.fetch("CLUSTER_CIDR", "10.42.0.0/16"))
    Log.info { "Loaded Kubernetes configuration" }
  end

  def watch_pods
    Log.info { "Starting pod watcher..." }

    spawn do
      # Watch all pods - watch_pods takes a block with Kubernetes::Watch
      @k8s.watch_pods do |watch|
        pod = watch.object

        pod_ip = pod.status["podIP"]?.try(&.as_s)
        next unless pod_ip
        next unless @cluster_cidr.matches?(pod_ip)

        @mutex.synchronize do
          case watch
          when .added?, .modified?
            @pod_map[pod_ip] = pod.metadata
            Log.info { "Updated pod map for IP #{pod_ip}: #{pod.metadata.namespace}/#{pod.metadata.name}" }
          when .deleted?
            if @pod_map.has_key?(pod_ip)
              @pod_map.delete(pod_ip)
              Log.info { "Removed pod from map: IP #{pod_ip}" }
            end
          end
        end
      end
    end
  end

  def get_pod_by_ip(ip : String) : Kubernetes::Pod::Metadata?
    @mutex.synchronize do
      @pod_map[ip]?
    end
  end

  def get_all_pods(namespace : String? = nil) : Hash(String, Kubernetes::Pod::Metadata)
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
