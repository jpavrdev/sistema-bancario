using BankingSystem.Domain.Enums;
using BankingSystem.Domain.ValueObjects;
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

    public static Usuario Criar(
        string cpf,
        string nome,
        string sobrenome,
        DateOnly dataNascimento,
        EstadoCivil? estadoCivil = null,
        Sexo? sexo = null
    )
    {
        var cpfResult = Cpf.Create(cpf);

        if (!cpfResult.IsSuccess)
            throw new ArgumentException(cpfResult.Error!.Description);

        if (string.IsNullOrWhiteSpace(nome))
            throw new ArgumentException("Nome é obrigatório.");

        if (string.IsNullOrWhiteSpace(sobrenome))
            throw new ArgumentException("Sobrenome é obrigatório.");

        if (dataNascimento == default)
            throw new ArgumentException("Data de nascimento é obrigatória.");

        var dataAgora = DateTimeOffset.UtcNow;

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
