# Pod Watcher Microservice

A Kubernetes microservice that watches for Pod changes via the K8s API and provides a REST API to query pod metadata by IP address.

I'm playing with K8s in my homelab and settled on using Fission for FaaS. I like it's general architecture and design,
but feel that it's lacking a little in authorization (though I understand that it's out of scope). To solve this, I
setup a Caddy server and use `forward_auth` to pre-flight the invocation request (the pre-flight check is also a Fission function - how's that for dogfooding?). I really wanted implicit authorization if the invocation originated
from the same namespace - this just seemed to make sense. However, all I really know about the originator is it's IP.
For originators with a k8s Service, I could do a reverse DNS query, but this doesn't work for Pods w/o a service. The alternative was to query the k8s API directly. That'd work, but finding a Pod given an IP is technically an O(n) operation (Garth's - my Data Structures and Algorithms professor's - voice still haunts me, telling my I can do better). This service watches Pods and caches their metadata, making the needed query O(1) (my inner Garth is appeased).

For small setups, it probably doesn't make much of a difference, but what's the fun in an under-engineered homelab?

This is probably somewhat niche - 
- My environment has a bunch of unrelated apps in it - it's a homelab like I said. More focused k8s clusters probably don't need to worry (like I really need to either!) this much about Fission isolation.
- In a production environment, it probably makes more sense to use JWTs (or some other, more-explicit option), but I didn't want to manage those all over the place.

*NB:* As of the initial commit, all code was written with GH Copilot. I performed some light review for any glaring issues, but take things here with some salt!

## Features

- Real-time monitoring of all pods across all namespaces
- Maintains an in-memory map of Pod IP to metadata
- REST API endpoints for querying pod information
- Health and readiness checks
- Supports both in-cluster and local development

## API Endpoints

### GET /pod?ip=<pod_ip>
Query pod metadata by IP address.

**Example:**
```bash
curl "http://pod-watcher:8080/pod?ip=10.42.0.5"
```

**Response:**
```json
{
  "name": "my-pod",
  "namespace": "default",
  "uid": "abc123...",
  "labels": {...},
  "pod_ip": "10.42.0.5",
  "node_name": "worker-1",
  "phase": "Running",
  ...
}
```

### GET /pods
Get all pods in the map. Optional `namespace` query parameter to filter.

**Example:**
```bash
curl "http://pod-watcher:8080/pods?namespace=kube-system"
```

### GET /health
Health check endpoint.

### GET /ready
Readiness check endpoint.

## Deployment

### Build the Docker image
```bash
docker build -t pod-watcher:latest .
```

### Deploy to Kubernetes
```bash
kubectl apply -f k8s/
```

## Local Development

```bash
pip install -r requirements.txt
python main.py
```

Make sure you have a valid kubeconfig for local development.
