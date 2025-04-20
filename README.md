[**Design**](docs/design.md) | [**Features**](docs/features.md) | [**Get Started**](docs/quickStart.md) | [**Troubleshooting**](docs/troubleshooting.md) | [**Parameters**](docs/parameters.md) | [**Scope**](docs/scope.md) | [**Zero Trust Framework**](docs/zeroTrustFramework.md)

# Federal Azure Virtual Desktop Automation

With this solution, you can deploy:

1. One (1) or more fully operational Azure Virtual Desktop hostpools - either pooled or personal.
2. Image management capability.
3. Custom Image build automation solution.

The code and automation capabilities of this repo can be used to deploy these capabilities in Azure Commercial, Azure US Government, **Azure Government Secret**, and **Azure Government Top Secret** environments. The code is designed to allow you to deploy in compliance with Microsoft's [Zero Trust principles](https://learn.microsoft.com/security/zero-trust/azure-infrastructure-avd) and [IL5 Isolation Guidance](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5).

The code is idempotent to allow all resources deployed via this solution to be redeployed without conflicts when the same parameters are used. The [resource organization](docs/design.md) follows CAF guidance and by changing the `identifier` parameter and/or the deployment location of the host pool deployment, you can deploy multiple host pools while sharing many resources to create an enterprise ready AVD solution including regional disaster recovery capabilities. Many of the [common features](docs/features.md) used with AVD have been automated in this solution for your convenience.

## Quick Start

For detailed step by step instructions to deploy the solution components including the prerequisites, see the [Quick Start Guide](docs/quickStart.md).

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
