function fillUserCode(code) {
    const inputFields = document.querySelectorAll('.js-user-code-field');
    if (inputFields.length !== code.length) {
      console.error("Code length does not match the number of input fields.");
      return;
    }
  
    for (let i = 0; i < inputFields.length; i++) {
      inputFields[i].value = code[i].toUpperCase(); // Fill input with uppercase characters
    }
}