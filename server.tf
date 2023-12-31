resource "random_shuffle" "location" {
  input = {
    "eu-central": ["fsn1", "nbg1", "hel1"],
    "us-east": ["ash"],
    "us-west": ["hil"]
  }[var.stack.zone]
  result_count = 1
}

resource "hcloud_server" "server" {
  depends_on = [
    hcloud_server.grafana,
    hcloud_server.nat_gateway
  ]

  for_each = local.server_map
  name        = local.server_map[each.key]["name"]
  server_type = local.server_map[each.key]["type"]
  image       = "ubuntu-22.04"
  ssh_keys    = [ data.hcloud_ssh_key.ssh_key.id ]

  location = random_shuffle.location.result[0]
  keep_disk   = true

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.network.id
  }


  labels = merge({
    "created-by" = "prvsn-hcloud-starter",
    "role" = "server"
    },
    contains(keys(local.target_servers_to_lb), each.key) ? { "subdomain" = local.target_servers_to_lb[each.key] } : {}
  )

  user_data = templatefile("${path.module}/cloud_init_server.tftpl", {
    network_gateway = hcloud_network_subnet.subnet.gateway,
    volume_linux_device_available = contains(keys(hcloud_volume.data), each.key)
    volume_linux_device = try(hcloud_volume.data[each.key].linux_device, null)
    hostname = local.server_map[each.key]["name"]
    loki_ip = local.loki_ip
    zip_files = {
      "node_exporter": filebase64(data.archive_file.compose_node_exporter.output_path)
      "promtail": filebase64(data.archive_file.compose_promtail.output_path)
    }
  })

  lifecycle {
    ignore_changes = [
      # Ignore changes to network.
      # We let an IP address to be assigned automatically. Terraform will assume the server needs to be recreated
      # on update, since the IP address was not specified in the network block.
      network
    ]
  }
}

resource "random_id" "volume" {
  byte_length = 4
}

resource "hcloud_volume" "data" {
  for_each = local.servers_with_volumes

  name              = replace("${local.servers_with_volumes[each.key]["name"]}-data-${random_id.volume.hex}", "/\\s+/", "")
  size              = local.servers_with_volumes[each.key]["data_volume_size"]
  location          = random_shuffle.location.result[0]
  format            = "ext4"
  delete_protection = false

  labels = {
    "created-by" = "prvsn",
    "role" = "data-volume",
    "server" = replace("${local.server_map[each.key]["name"]}-data-${random_id.volume.hex}", "/\\s+/", "")
  }
}

resource "hcloud_volume_attachment" "main" {
  for_each = local.servers_with_volumes

  volume_id = hcloud_volume.data[each.key].id
  server_id = hcloud_server.server[each.key].id
  automount = false
}
