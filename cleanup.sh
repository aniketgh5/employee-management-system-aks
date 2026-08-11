#!/bin/bash
set -e
echo "Deleting application..."
kubectl delete -k aks/ --ignore-not-found=true
echo "Deleting employee-app namespace..."
kubectl delete namespace employee-app --ignore-not-found=true
echo "Removing ingress-nginx..."
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
echo "Deleting ingress-nginx namespace..."
kubectl delete namespace ingress-nginx --ignore-not-found=true
echo "Cleanup complete."
kubectl get namespaces
