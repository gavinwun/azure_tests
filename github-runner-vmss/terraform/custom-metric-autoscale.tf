#####################################################################
# Custom-metric VMSS autoscaling - vmss backend only.
#
# ACI has no equivalent Azure Monitor autoscale target - the ACI
# backend's poller workflow (reconcile-aci-runners.yml) creates and
# deletes container groups directly instead. See aci.tf.
#####################################################################

resource "azurerm_monitor_autoscale_setting" "vmss_queue_autoscale" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                = "autoscale-${local.vmss_name}"
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss[0].id
  tags                = local.tags

  profile {
    name = "queue-depth"

    capacity {
      minimum = var.queue_autoscale_min_instances
      maximum = var.queue_autoscale_max_instances
      default = var.queue_autoscale_default_instances
    }

    # Scale OUT when queued jobs per instance exceeds the threshold
    rule {
      metric_trigger {
        metric_name              = var.custom_metric_name
        metric_namespace         = var.custom_metric_namespace
        metric_resource_id       = azurerm_linux_virtual_machine_scale_set.vmss[0].id
        time_grain                = "PT1M"
        statistic                 = "Average"
        time_window                = "PT5M"
        time_aggregation           = "Average"
        operator                   = "GreaterThanOrEqual"
        threshold                  = var.queue_messages_per_instance
        divide_by_instance_count   = true
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT${var.queue_scale_out_cooldown_minutes}M"
      }
    }

    # Scale IN when the queue is quiet
    rule {
      metric_trigger {
        metric_name              = var.custom_metric_name
        metric_namespace         = var.custom_metric_namespace
        metric_resource_id       = azurerm_linux_virtual_machine_scale_set.vmss[0].id
        time_grain                = "PT1M"
        statistic                 = "Average"
        time_window                = "PT5M"
        time_aggregation           = "Average"
        operator                   = "LessThan"
        threshold                  = var.queue_messages_per_instance
        divide_by_instance_count   = true
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT${var.queue_scale_in_cooldown_minutes}M"
      }
    }
  }
}
