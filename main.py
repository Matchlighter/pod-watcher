#!/usr/bin/env python3
"""
Pod Watcher Microservice
Watches Kubernetes pods and maintains a mapping of Pod IPs to metadata.
Provides a REST API to query pod information by IP address.
"""

import logging
import threading
from flask import Flask, jsonify, request
from kubernetes import client, config, watch
import os
import sys

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Global dictionary to store pod IP to metadata mapping
pod_map = {}
pod_map_lock = threading.Lock()


def load_kubernetes_config():
    """Load Kubernetes configuration (in-cluster or local kubeconfig)"""
    try:
        # Try to load in-cluster config first (when running in K8s)
        config.load_incluster_config()
        logger.info("Loaded in-cluster Kubernetes configuration")
    except config.ConfigException:
        try:
            # Fall back to local kubeconfig (for local development)
            config.load_kube_config()
            logger.info("Loaded local Kubernetes configuration")
        except config.ConfigException:
            logger.error("Could not load Kubernetes configuration")
            sys.exit(1)


def extract_pod_metadata(pod):
    """Extract relevant metadata from a pod object"""
    metadata = {
        'name': pod.metadata.name,
        'namespace': pod.metadata.namespace,
        'uid': pod.metadata.uid,
        'labels': pod.metadata.labels or {},
        'annotations': pod.metadata.annotations or {},
        'node_name': pod.spec.node_name,
        'phase': pod.status.phase,
        'pod_ip': pod.status.pod_ip,
        'host_ip': pod.status.host_ip,
        'start_time': pod.status.start_time.isoformat() if pod.status.start_time else None,
        'conditions': []
    }
    
    # Extract pod conditions
    if pod.status.conditions:
        for condition in pod.status.conditions:
            metadata['conditions'].append({
                'type': condition.type,
                'status': condition.status,
                'reason': condition.reason,
                'message': condition.message
            })
    
    # Extract container information
    metadata['containers'] = []
    if pod.spec.containers:
        for container in pod.spec.containers:
            metadata['containers'].append({
                'name': container.name,
                'image': container.image,
                'ports': [{'containerPort': p.container_port, 'protocol': p.protocol} 
                         for p in (container.ports or [])]
            })
    
    return metadata


def watch_pods():
    """Watch for pod changes and update the pod map"""
    v1 = client.CoreV1Api()
    w = watch.Watch()
    
    logger.info("Starting pod watcher...")
    
    # Initial listing to populate the map
    try:
        pod_list = v1.list_pod_for_all_namespaces()
        with pod_map_lock:
            for pod in pod_list.items:
                if pod.status.pod_ip:
                    pod_map[pod.status.pod_ip] = extract_pod_metadata(pod)
        logger.info(f"Initial pod map populated with {len(pod_map)} pods")
    except Exception as e:
        logger.error(f"Error during initial pod listing: {e}")
    
    # Watch for pod changes
    while True:
        try:
            for event in w.stream(v1.list_pod_for_all_namespaces, timeout_seconds=0):
                event_type = event['type']
                pod = event['object']
                pod_ip = pod.status.pod_ip
                
                logger.debug(f"Event: {event_type} for pod {pod.metadata.name} in {pod.metadata.namespace}")
                
                with pod_map_lock:
                    if event_type in ['ADDED', 'MODIFIED']:
                        if pod_ip:
                            pod_map[pod_ip] = extract_pod_metadata(pod)
                            logger.info(f"Updated pod map for IP {pod_ip}: {pod.metadata.namespace}/{pod.metadata.name}")
                    elif event_type == 'DELETED':
                        if pod_ip and pod_ip in pod_map:
                            del pod_map[pod_ip]
                            logger.info(f"Removed pod from map: IP {pod_ip}")
                        
        except Exception as e:
            logger.error(f"Error in pod watcher: {e}")
            logger.info("Restarting watch stream in 5 seconds...")
            import time
            time.sleep(5)


@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'healthy', 'pod_count': len(pod_map)}), 200


@app.route('/ready', methods=['GET'])
def ready():
    """Readiness check endpoint"""
    if len(pod_map) > 0:
        return jsonify({'status': 'ready', 'pod_count': len(pod_map)}), 200
    else:
        return jsonify({'status': 'not ready', 'pod_count': 0}), 503


@app.route('/pod', methods=['GET'])
def get_pod_by_ip():
    """Query pod metadata by IP address"""
    ip = request.args.get('ip')
    
    if not ip:
        return jsonify({'error': 'IP parameter is required'}), 400
    
    with pod_map_lock:
        if ip in pod_map:
            return jsonify(pod_map[ip]), 200
        else:
            return jsonify({'error': f'No pod found with IP {ip}'}), 404


@app.route('/pods', methods=['GET'])
def get_all_pods():
    """Get all pods in the map"""
    namespace = request.args.get('namespace')
    
    with pod_map_lock:
        if namespace:
            filtered_pods = {ip: metadata for ip, metadata in pod_map.items() 
                           if metadata['namespace'] == namespace}
            return jsonify({'pods': filtered_pods, 'count': len(filtered_pods)}), 200
        else:
            return jsonify({'pods': pod_map, 'count': len(pod_map)}), 200


def main():
    """Main entry point"""
    logger.info("Starting Pod Watcher Microservice")
    
    # Load Kubernetes configuration
    load_kubernetes_config()
    
    # Start the pod watcher in a separate thread
    watcher_thread = threading.Thread(target=watch_pods, daemon=True)
    watcher_thread.start()
    
    # Start Flask API server
    port = int(os.environ.get('PORT', 8080))
    host = os.environ.get('HOST', '0.0.0.0')
    
    logger.info(f"Starting Flask API on {host}:{port}")
    app.run(host=host, port=port, debug=False)


if __name__ == '__main__':
    main()
