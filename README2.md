1. Criar a Solution e os projetos

# Cria a solution
dotnet new sln -n BankingSystem

# Cria os projetos (É a estrutura comum para projetos)
dotnet new webapi -n BankingSystem.API
dotnet new classlib -n BankingSystem.Application
dotnet new classlib -n BankingSystem.Domain
dotnet new classlib -n BankingSystem.Infrastructure
dotnet new xunit -n BankingSystem.Tests

# Adiciona todos a solution
dotnet sln add BankingSystem.API/BankingSystem.API.csproj
dotnet sln add BankingSystem.Application/BankingSystem.Application.csproj
dotnet sln add BankingSystem.Domain/BankingSystem.Domain.csproj
dotnet sln add BankingSystem.Infrastructure/BankingSystem.Infrastructure.csproj
dotnet sln add BankingSystem.Tests/BankingSystem.Tests.csproj

2. Referenciar os projetos entre si
# API depende de Application
dotnet add BankingSystem.API/BankingSystem.API.csproj reference BankingSystem.Application/BankingSystem.Application.csproj

# Application depende de Domain
dotnet add BankingSystem.Application/BankingSystem.Application.csproj reference BankingSystem.Domain/BankingSystem.Domain.csproj

# Infrastructure depende de Application e Domain
dotnet add BankingSystem.Infrastructure/BankingSystem.Infrastructure.csproj reference BankingSystem.Domain/BankingSystem.Domain.csproj
dotnet add BankingSystem.Infrastructure/BankingSystem.Infrastructure.csproj reference BankingSystem.Application/BankingSystem.Application.csproj

# API depende de Infrastructure
dotnet add BankingSystem.API/BankingSystem.API.csproj reference BankingSystem.Infrastructure/BankingSystem.Infrastructure.csproj

3. Estrutura resultante
BankingSystem/
├── BankingSystem.API/          # Controllers, Program.cs, configs
├── BankingSystem.Application/  # Use cases, DTOs, interfaces
├── BankingSystem.Domain/       # Entidades, regras de negócio
├── BankingSystem.Infrastructure/ # EF Core, repositórios, banco
└── BankingSystem.Tests/        # Testes unitários/integração
