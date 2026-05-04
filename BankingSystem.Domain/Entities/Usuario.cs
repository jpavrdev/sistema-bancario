using BankingSystem.Domain.Enums;
using BankingSystem.Domain.ValueObjects;
using BankingSystem.Domain.Common;

namespace BankingSystem.Domain.Entities;

public sealed class Usuario
{
    public Guid Id { get; private set; }
    public Cpf Cpf { get; private set; } = null!;
    public string Nome { get; private set; } = null!;
    public string Sobrenome { get; private set; } = null!;
    public DateOnly DataNascimento { get; private set; }
    public EstadoCivil? EstadoCivil { get; private set; }
    public Sexo? Sexo { get; private set; }
    public DateTimeOffset? AnonimizadoEm { get; private set; }
    public DateTimeOffset CriadoEm { get; private set; }
    public DateTimeOffset AtualizadoEm { get; private set; }

    private Usuario() { }

    public static Result<Usuario> Criar(
        string cpf,
        string nome,
        string sobrenome,
        DateOnly dataNascimento,
        TimeProvider timeProvider,
        EstadoCivil? estadoCivil = null,
        Sexo? sexo = null
    )
    {
        var cpfResult = Cpf.Create(cpf);

        if (!cpfResult.IsSuccess)
            return new Error("UsuarioInvalido", ErrorType.Validation, "CPF é inválido.");

        if (string.IsNullOrWhiteSpace(nome))
            return new Error("UsuarioInvalido", ErrorType.Validation, "Nome é obrigatório.");

        if (string.IsNullOrWhiteSpace(sobrenome))
            return new Error("UsuarioInvalido", ErrorType.Validation, "Sobrenome é obrigatório.");

        if (dataNascimento == default)
            return new Error("UsuarioInvalido", ErrorType.Validation, "Data de Nascimento é obrigatória.");

        var dataAgora = timeProvider.GetUtcNow();

        return new Usuario
        {
            Id = Guid.NewGuid(),
            Cpf = cpfResult.Value!,
            Nome = nome,
            Sobrenome = sobrenome,
            DataNascimento = dataNascimento,
            EstadoCivil = estadoCivil,
            Sexo = sexo,
            CriadoEm = dataAgora,
            AtualizadoEm = dataAgora
        };
    }
}
