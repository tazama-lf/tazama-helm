# Setting up a local kubernetes environment

This tutorial will use [k3d](https://k3d.io) as it "makes it very easy to create single- and multi-node [k3s](https://github.com/rancher/k3s) clusters in docker, e.g. for local development on Kubernetes".

k3d is a lightweight wrapper to run k3s (a minimal Kubernetes distribution) in docker.

## Requirements

`docker`

`kubectl` - for interacting with the cluster

`helm`

### Installing kubectl

See [Upstream kubernetes documentation](https://kubernetes.io/docs/tasks/tools/#kubectl):

- [Install and Set Up kubectl on Linux | Kubernetes](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)

- [Install and Set Up kubectl on macOS | Kubernetes](https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/)

- [Install and Set Up kubectl on Windows | Kubernetes](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)


## Installing k3d

k3d is available through homebrew (MacOS/Linux), chocolatey and scoop (Windows):

[An upstream list of platforms where the package is available](https://github.com/k3d-io/k3d/tree/46f3480daa747ba71c155d0f619ce6aba7b95db9#releases)

Depending on your platform and your preferred method of installation, you would run one of the following

- Homebrew: `brew install k3d`

- Chocolatey: `choco install k3d`

- Scoop: `scoop install k3d`

Or alternatively, installing the latest release from the upstream shell script:

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

### Verifying installation

Run the following commands to see if all your dependencies are ready

```shell
docker version
k3d version
kubectl version --client
helm version
git --version
```

All commands should run successfully 

# Creating a local cluster

Now we can proceed to creating a cluster named tazama-demo. For the purpose of this document, we will create one with one server node and one agent node.

```
k3d cluster create tazama-demo --servers 1 --agents 1 --wait -p "18080:80@loadbalancer"
```

Where we map the host port 18080 to the cluster's ingress HTTP port.

If ports `18080` is already in use, replace the host-side port number. For example:

```
-p "9080:80@loadbalancer"
```

## Verify the cluster

- List your cluster by running: `k3d cluster list`

- Check that kubectl is using the new cluster `kubectl config current-context`:
  
  - we expect the output to be `k3d-tazama-demo`

> [!WARNING]  
> Ensure you're using the `k3d-tazama-demo` cluster. Running commands on the wrong cluster will affect resources in another environment. Do not proceed until you have verified that you are connected to the intended local testing cluster.

- Check the system workloads:
  
  - `kubectl get pods --all-namespaces`


> [!NOTE]  
> Some pods may briefly show `Pending` or `ContainerCreating` immediately after cluster creation. Give it a minute or two to become ready before you start installing helm charts.

# Stopping the Cluster

`k3d cluster stop tazama-demo`



# Starting the Cluster

`k3d cluster start tazama-demo`

### Destroy the cluster

Deleting the cluster permanently removes its k3d containers and cluster state:

```
k3d cluster delete helm-testing
```

Confirm that it was removed:

```
k3d cluster list
```

> Data stored only inside the cluster is deleted with the cluster. Do not use the local cluster for data that must be retained.

# Deploying a helm chart

We will use `valkey` to test our local cluster

```
helm repo add valkey https://valkey.io/valkey-helm/
```

Update your local cache:

```
helm repo update
```

Install the chart:

```
helm install valkey valkey/valkey
```

Run `kubectl get pod --all-namespaces` and wait until valkey in the default namespace is `READY` and the status is `Running`.

# Misc

Should you prefer to use other tooling such as [kind](https://kind.sigs.k8s.io/) or [minikube](https://minikube.sigs.k8s.io/), Kubernetes does have guides and demos available:

- [Kind](https://kubernetes.io/docs/tasks/tools/#kind)

- [Minikube](https://kubernetes.io/docs/tasks/tools/#minikube)

- [Kubeadm](https://kubernetes.io/docs/tasks/tools/#kubeadm)
