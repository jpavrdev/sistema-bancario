using BankingSystem.Domain.Enums;

namespace BankingSystem.Domain.Entities;

public class Contrato
{
    public Guid Id { get; private set; }
    public Guid UsuarioId { get; private set; }
    public string Descricao { get; private set; } = null!;
    public decimal ValorTotalFinanciado { get; private set; }
    public decimal TaxaJurosMensal { get; private set; }
    public decimal TaxaMultaAtraso  { get; private set; }
    public StatusContrato Status { get; private set; }
    public DateTimeOffset DataAssinatura { get; private set; }
    public DateTimeOffset CriadoEm { get; private set; }

    private Contrato() { }

    public static Contrato Criar(
        Guid usuarioId,
        string descricao,
        decimal valorTotalFinanciado,
        decimal taxaJurosMensal,
        decimal taxaMultaAtraso,
        StatusContrato status = StatusContrato.Ativo
    ) {
        if (string.IsNullOrWhiteSpace(descricao))
            throw new ArgumentException("Descrição é obrigatória.");

        if (valorTotalFinanciado <= 0)
            throw new ArgumentException("Valor Total Financiado Não pode ser negativo.");

        if (taxaJurosMensal < 0)
            throw new ArgumentException("Taxa de Juros não pode ser negativa.");

        if (taxaMultaAtraso < 0)
            throw new ArgumentException("Taxa de multa não pode ser negativa.");

        return new Contrato
        {
            Id = Guid.NewGuid(),
            UsuarioId = usuarioId,
            Descricao = descricao,
            ValorTotalFinanciado = valorTotalFinanciado,
            TaxaJurosMensal = taxaJurosMensal,
            TaxaMultaAtraso = taxaMultaAtraso,
            Status = status,
            DataAssinatura = DateTimeOffset.UtcNow,
            CriadoEm = DateTimeOffset.UtcNow
        };
    }
}
