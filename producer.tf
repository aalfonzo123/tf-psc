resource "google_compute_network" "vpc-producer" {
  name                    = "vpc-producer"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpc-producer-psc" {
  name          = "vpc-producer-psc"
  ip_cidr_range = "10.1.0.0/24"
  region        = "us-west4"
  purpose       = "PRIVATE_SERVICE_CONNECT"
  network       = google_compute_network.vpc-producer.id
}

resource "google_compute_subnetwork" "vpc-vpc-producer-us-west4" {
  name          = "vpc-producer-us-west4"
  ip_cidr_range = "10.2.0.0/24"
  region        = "us-west4"
  network       = google_compute_network.vpc-producer.id
}

resource "google_compute_service_attachment" "psc-service-attachment" {
  name   = "psc-service-attachment"
  region = "us-west4"

  enable_proxy_protocol = false
  #domain_names             = ["gcp.tfacc.hashicorptest.com."]
  connection_preference = "ACCEPT_MANUAL"
  nat_subnets           = [google_compute_subnetwork.vpc-producer-psc.id]
  target_service        = google_compute_forwarding_rule.producer-forwarding-rule.id

  consumer_accept_lists {
    project_id_or_num = "alf-project-431219"
    connection_limit  = 4
  }
}

resource "google_compute_forwarding_rule" "producer-forwarding-rule" {
  name                  = "producer-forwarding-rule"
  backend_service       = google_compute_region_backend_service.backend-service.id
  region                = "us-west4"
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL"
  all_ports             = true
  allow_global_access   = true
  network               = google_compute_network.vpc-producer.id
  subnetwork            = google_compute_subnetwork.vpc-vpc-producer-us-west4.id
}

resource "google_compute_region_backend_service" "backend-service" {
  name = "backend-service"

  region                = "us-west4"
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_region_health_check.region-hc.id]
  backend {
    group          = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_instance_template" "instance-template" {
  name         = "instance-template"
  machine_type = "e2-small"
  tags         = ["allow-ssh", "allow-health-check"]

  network_interface {
    network    = google_compute_network.vpc-producer.id
    subnetwork = google_compute_subnetwork.vpc-vpc-producer-us-west4.id
  }
  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  # install nginx and serve a simple web page
  metadata = {
    enable-oslogin = "true"
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }

  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    instance_termination_action = "STOP"
  }


}

# health check
resource "google_compute_region_health_check" "region-hc" {
  name = "region-hc"

  region = "us-west4"
  http_health_check {
    port = "80"
  }
}

resource "google_compute_region_instance_group_manager" "mig" {
  name = "mig"

  region = "us-west4"
  version {
    instance_template = google_compute_instance_template.instance-template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 1
}

# allow all access from health check ranges
resource "google_compute_firewall" "fw-hc" {
  name          = "fw-hc"
  direction     = "INGRESS"
  network       = google_compute_network.vpc-producer.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
  target_tags = ["allow-health-check"]
}

# allow communication within the subnet 
resource "google_compute_firewall" "fw-ilb-to-backends" {
  name          = "fw-ilb-to-backends"
  direction     = "INGRESS"
  network       = google_compute_network.vpc-producer.id
  source_ranges = ["10.1.0.0/24"]
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

# allow SSH
resource "google_compute_firewall" "fw-ilb-ssh" {
  name      = "fw-ilb-ssh"
  direction = "INGRESS"
  network   = google_compute_network.vpc-producer.id
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}


resource "google_compute_router" "router" {
  name    = "router"
  region  = "us-west4"
  network = google_compute_network.vpc-producer.id

  # bgp {
  #   asn = 64514
  # }
}

resource "google_compute_router_nat" "nat" {
  name                               = "my-router-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}