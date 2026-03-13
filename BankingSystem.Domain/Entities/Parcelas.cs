using BankingSystem.Domain.Entities;
using BankingSystem.Domain.Enums;

namespace BankingSystem.Domain.Entities;

public class Parcelas
{
    public Guid Id { get; private set; }
    public Guid ContratoId { get; private set; }
    public int NumeroParcela { get; private set; }
    public decimal ValorPrincipal { get; private set; }
    public DateTimeOffset DataVencimento { get; private set; }
    public StatusContrato Status { get; private set; }
    public decimal SaldoDevedor { get; private set; }
    public int Versao { get; private set; }
    public DateTimeOffset CriadoEm { get; private set; }

}
