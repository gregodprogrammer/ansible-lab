output "public_ips" {
  value = {
    web1_app1 = azurerm_linux_virtual_machine.main[0].public_ip_address
    web2_db1  = azurerm_linux_virtual_machine.main[1].public_ip_address
  }
}

output "vm_names" {
  value = [for vm in azurerm_linux_virtual_machine.main : vm.name]
}

output "inventory_note" {
  value = "vm-web1 serves web1+app1 roles | vm-web2 serves web2+db1 roles"
}
