param vmname string
param vmuser string
@secure()
param vmpass string
param prefix string
param publickey string

var location = resourceGroup().location

resource nsg 'Microsoft.Network/networkSecurityGroups@2020-07-01' = {
    name: '${vmname}-nsg'
    location: location
    properties: {
        securityRules: [
            {
                name: 'allow-ssh'
                properties: {
                    priority: 110
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '22'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: '*'
                    access: 'Allow'
                    direction: 'Inbound'
                }
            }
        ]
    }
}

resource vnet 'Microsoft.Network/virtualNetworks@2020-07-01' = {
    name: '${vmname}-vnet'
    location: location
    properties: {
        addressSpace: {
            addressPrefixes: [
                '10.0.0.0/16'
            ]
        }
        subnets: [
            {
                name: 'default'
                properties: {
                    addressPrefix: '10.0.0.0/24'
                    networkSecurityGroup: {
                        id: nsg.id
                    }
                }
            }
        ]
    }
}

resource pip 'Microsoft.Network/publicIPAddresses@2020-07-01' = {
    name: '${vmname}-pip'
    location: location
    sku: {
        name: 'Basic'
    }
    properties: {
        dnsSettings: {
            domainNameLabel: prefix
        }
    }
}

resource nic 'Microsoft.Network/networkInterfaces@2020-07-01' = {
    name: '${vmname}-nic'
    location: location
    properties: {
        ipConfigurations: [
            {
                name: 'ifcfg'
                properties: {
                    publicIPAddress: {
                        id: pip.id
                    }
                    subnet: {
                        id: vnet.properties.subnets[0].id
                    }
                }
            }
        ]
    }
}

resource vm 'Microsoft.Compute/virtualMachines@2020-12-01' = {
    name: vmname
    location: location
    properties: {
        hardwareProfile: {
            //vmSize: 'Standard_B2ms'
            vmSize: 'Standard_D2ds_v4'
        }
        storageProfile: {
            imageReference: {
                publisher: 'MicrosoftWindowsServer'
                offer: 'WindowsServer'
                sku: '2019-datacenter-smalldisk-g2'
                version: 'latest'
            }
            osDisk: {
                osType: 'Windows'
                name: '${vmname}-osdisk'
                createOption: 'FromImage'
                diffDiskSettings: {
                    option: 'Local'
                }
            }
        }
        osProfile: {
            computerName: vmname
            adminUsername: vmuser
            adminPassword: vmpass
        }
        networkProfile: {
            networkInterfaces: [
                {
                    id: nic.id
                }
            ]
        }
    }
}

resource extension 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = {
    name: '${vmname}/config-app'
    location: location
    dependsOn: [
        vm
    ]
    properties: {
        publisher: 'Microsoft.Compute'
        type: 'CustomScriptExtension'
        typeHandlerVersion: '1.10'
        autoUpgradeMinorVersion: true
        settings: {
            fileUris: [
                'https://a9aee37ade8f.ngrok.io/setup.ps1'
            ]
            timestamp: 0
            commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File setup.ps1 -Publickey "${publickey}"'
        }
    }
}
