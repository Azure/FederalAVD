@secure()
param administratorAccountUsernameValue string

@secure()
param administratorAccountUsernameSecretUri string

@secure()
param administratorAccountPasswordSecretUri string
param domain string
param ouPath string

var domain_var = ((domain == '') ? last(split(administratorAccountUsernameValue, '@')) : domain)
var sessionHostConfigurationDomainActiveDirectoryInfoProps = {
  domainName: domain_var
  ouPath: ouPath
  domainCredentials: {
    usernameKeyVaultSecretUri: administratorAccountUsernameSecretUri
    passwordKeyVaultSecretUri: administratorAccountPasswordSecretUri
  }
}

output domain string = domain_var
output sessionHostConfigurationDomainActiveDirectoryInfoProps object = sessionHostConfigurationDomainActiveDirectoryInfoProps

