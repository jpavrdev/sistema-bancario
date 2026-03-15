using BankingSystem.Domain.Enums;
using BankingSystem.Domain.Common;

namespace BankingSystem.Domain.Entities;

public sealed class Parcela
{
    public Guid Id { get; private set; }
    public Guid ContratoId { get; private set; }
    public int NumeroParcela { get; private set; }
    public decimal ValorPrincipal { get; private set; }
    public DateTimeOffset DataVencimento { get; private set; }
    public StatusParcela Status { get; private set; }
    public decimal SaldoDevedor { get; private set; }
    public int Versao { get; private set; }
    public DateTimeOffset CriadoEm { get; private set; }

    private Parcela() {}

    public static Result<Parcela> Criar(
        Guid contratoId,
        int numeroParcela,
        decimal valorPrincipal,
        decimal saldoDevedor,
        DateTimeOffset dataVencimento,
        StatusParcela status = StatusParcela.Pendente
    ) {
        if (contratoId == Guid.Empty)
            return new Error("ParcelaInvalida", ErrorType.Validation, "ContratoId é obrigatório.");

        if (numeroParcela <= 0)
            return new Error("ParcelaInvalida", ErrorType.Validation, "Número da parcela deve ser maior que zero.");

        if (valorPrincipal <= 0)
            return new Error("ParcelaInvalida", ErrorType.Validation, "Valor Principal deve ser maior que zero.");

        var dataAgora = DateTimeOffset.UtcNow;

        return new Parcela
        {
            Id = Guid.NewGuid(),
            ContratoId = contratoId,
            NumeroParcela = numeroParcela,
            ValorPrincipal = valorPrincipal,
            SaldoDevedor = saldoDevedor,
            DataVencimento = dataVencimento,
            Status = status,
            CriadoEm = dataAgora
        };
    }

}
