using BankingSystem.Domain.Enums;

namespace BankingSystem.Domain.Entities;

public class Usuario
{
    public Guid Id { get; private set; }
    public string Cpf { get; private set; } = null!;
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
        if (string.IsNullOrWhiteSpace(cpf) || cpf.Length != 11)
            throw new ArgumentException("CPF inválido.");

        if (string.IsNullOrWhiteSpace(nome))
            throw new ArgumentException("Nome é obrigatório.");

        if (string.IsNullOrWhiteSpace(sobrenome))
            throw new ArgumentException("Sobrenome é obrigatório.");

        return new Usuario
        {
            Id = Guid.NewGuid(),
            Cpf = cpf,
            Nome = nome,
            Sobrenome = sobrenome,
            DataNascimento = dataNascimento,
            EstadoCivil = estadoCivil,
            Sexo = sexo,
            CriadoEm = DateTimeOffset.UtcNow,
            AtualizadoEm = DateTimeOffset.UtcNow
        };
    }
}
