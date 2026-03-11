using BankingSystem.Domain.ValueObjects;
using BankingSystem.Domain.Common;

namespace BankingSystem.Tests.ValueObjects;

public class CpfTests
{
    [Fact]
    public void Create_ComCpfValido_DeveRetornarSucesso()
    {
        var cpfValido = "52998224725";

        var result = Cpf.Create(cpfValido);

        Assert.True(result.IsSuccess);
        Assert.Equal("52998224725", result.Value!.Value);
    }

    [Theory]
    [InlineData("00000000000")]
    [InlineData("11111111111")]
    [InlineData("12345678901")]
    [InlineData("abcdefghijk")]
    public void Create_ComCpfInvalido_DeveRetornarFalha(string cpfInvalido)
    {
        var result = Cpf.Create(cpfInvalido);
        Assert.False(result.IsSuccess);
    }

    [Fact]
    public void Create_ComCpfFormatado_DeveRetornarSucesso()
    {
        var result = Cpf.Create("529.982.247-25");

        Assert.True(result.IsSuccess);
        Assert.Equal("52998224725", result.Value!.Value);
    }

    [Fact]
    public void ToString_DeveRetornarCpfFormatado()
    {
        var cpf = Cpf.Create("52998224725").Value!;

        Assert.Equal("529.982.247-25", cpf.ToString());
    }
}
