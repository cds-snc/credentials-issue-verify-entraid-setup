## Prerequisites

**PowerShell:** Version 7.0 or higher is recommended for Microsoft Graph compatibility.

**Permissions:** You need *Groups Administrator* or *Application Administrator* rights in your Azure/Entra ID tenant.

**Required Data:** Have your *Environment Name*, *Azure Application ID*, and *Tenant ID* ready.

## Setup Steps
    1. Open PowerShell: Run your PowerShell console as an Administrator.
    2. Set Execution Policy to ensure your system allows script execution by running:
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
## Execution Instructions
    1. Navigate to setup script folder and execute it:
        .\setup.ps1
    2. Provide Environment: Type your target environment name (e.g., dev) when prompted and press Enter.
    3. Provide App ID: Paste your Azure Application ID and press Enter.
    4. Provide Tenant ID: Paste your Azure Tenant ID and press Enter.
    5. Authenticating: If prompted by the Microsoft.Graph module later in the script, follow the on-screen instructions to log into your Azure account via the web browser.
