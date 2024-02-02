/**
 * Map keys from object to class
 * 
 * @param {object} objFrom 
 * @param {class}  objTo 
 * @returns {class}
 */
export const mapObjectKeys = (objFrom, objTo) => {
    const x = new objTo()
    for(const k in objFrom) {
        x[k] = objFrom[k]
    }
    return x
}