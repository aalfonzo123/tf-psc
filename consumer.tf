resource "google_compute_network" "vpc-consumer" {
  name                    = "vpc-consumer"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpc-consumer-us-west4" {
  name          = "vpc-consumer-us-west4"
  ip_cidr_range = "10.3.0.0/24"
  region        = "us-west4"
  network       = google_compute_network.vpc-consumer.id
}

resource "google_compute_address" "address-consumer-forwarding-rule" {
  name   = "address-consumer-forwarding-rule"
  region = "us-west4"

  subnetwork   = google_compute_subnetwork.vpc-consumer-us-west4.id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "consumer-forwarding-rule" {
  name   = "consumer-forwarding-rule"
  region = "us-west4"

  target                = google_compute_service_attachment.psc-service-attachment.id
  load_balancing_scheme = "" # need to override EXTERNAL default when target is a service attachment
  network               = google_compute_network.vpc-consumer.id
  ip_address            = google_compute_address.address-consumer-forwarding-rule.id
}

### test vm
resource "google_service_account" "simple-sa" {
  account_id   = "simple-sa"
  display_name = "Custom SA for VM Instance"
}

resource "google_compute_instance" "vm-consumer-test" {
  name         = "vm-consumer-test"
  machine_type = "e2-small"
  zone         = "us-west4-a"

  boot_disk {
    initialize_params {
      image = "debian-12"
      #size  = 30
    }
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.vpc-consumer-us-west4.id
  }

  service_account {
    email  = google_service_account.simple-sa.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    instance_termination_action = "STOP"
  }

  metadata = {
    "enable-oslogin" = "true"
  }
}

# allow SSH
resource "google_compute_firewall" "fw-ilb-ssh-consumer" {
  name      = "fw-ilb-ssh-consumer"
  direction = "INGRESS"
  network   = google_compute_network.vpc-consumer.id
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}